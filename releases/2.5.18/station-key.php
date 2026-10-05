<?php
declare(strict_types=1);
require_once __DIR__.'/lib/bootstrap.php';

if(!cc_installed()){header('Location: app/setup.php');exit;}
$me=cc_require_admin();
if(!cc_role_has_permission((string)$me['role'],'locations.manage')){http_response_code(403);exit('Locations permission required.');}
cc_start_session();
$db=cc_db();
$db->exec("CREATE TABLE IF NOT EXISTS location_station_keys (location_id INTEGER PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, rotated_at TEXT, last_used_at TEXT, FOREIGN KEY(location_id) REFERENCES locations(id) ON DELETE CASCADE)");
$db->exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_location_station_keys_hash ON location_station_keys(token_hash)");

function sk_h(string $s): string{return htmlspecialchars($s,ENT_QUOTES|ENT_SUBSTITUTE,'UTF-8');}
function sk_csrf(): string{if(empty($_SESSION['cc_station_key_csrf'])||!is_string($_SESSION['cc_station_key_csrf']))$_SESSION['cc_station_key_csrf']=bin2hex(random_bytes(32));return $_SESSION['cc_station_key_csrf'];}
function sk_format(string $raw): string{return implode('-',str_split(strtoupper($raw),8));}
function sk_canonical(string $shown): string{return strtoupper(preg_replace('/[^A-F0-9]/i','',$shown)??'');}

$flash='';$flashType='ok';$newKey='';$newLocation='';
if($_SERVER['REQUEST_METHOD']==='POST'){
    try{
        if(!hash_equals(sk_csrf(),(string)($_POST['csrf']??'')))throw new RuntimeException('This form expired. Reload and try again.');
        $action=(string)($_POST['action']??'');$locationId=max(0,(int)($_POST['location_id']??0));
        $q=$db->prepare('SELECT id,name FROM locations WHERE id=? AND active=1');$q->execute([$locationId]);$loc=$q->fetch();if(!$loc)throw new RuntimeException('Choose an active location.');
        if($action==='generate'){
            $canonical=strtoupper(bin2hex(random_bytes(16)));
            $shown=sk_format($canonical);
            $hash=hash('sha256',$canonical);
            $db->prepare("INSERT INTO location_station_keys(location_id,token_hash,created_at,rotated_at,last_used_at) VALUES(?,?,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,NULL) ON CONFLICT(location_id) DO UPDATE SET token_hash=excluded.token_hash,rotated_at=CURRENT_TIMESTAMP,last_used_at=NULL")->execute([$locationId,$hash]);
            try{$db->prepare("INSERT INTO audit_log(actor_type,actor_id,action,details) VALUES('user',?,'station_key_generated',?)")->execute([(int)$me['id'],'Permanent Station Key generated for '.(string)$loc['name']]);}catch(Throwable $e){}
            $newKey=$shown;$newLocation=(string)$loc['name'];$flash='New permanent Station Key created. The previous Station Key for this location is no longer valid.';
        }elseif($action==='revoke'){
            $db->prepare('DELETE FROM location_station_keys WHERE location_id=?')->execute([$locationId]);
            try{$db->prepare("INSERT INTO audit_log(actor_type,actor_id,action,details) VALUES('user',?,'station_key_revoked',?)")->execute([(int)$me['id'],'Permanent Station Key revoked for '.(string)$loc['name']]);}catch(Throwable $e){}
            $flash='Station Key revoked for '.(string)$loc['name'].'.';
        }else throw new RuntimeException('Unknown action.');
    }catch(Throwable $e){$flash=$e->getMessage();$flashType='bad';}
}
$locations=$db->query("SELECT l.id,l.name,l.active,k.created_at,k.rotated_at,k.last_used_at FROM locations l LEFT JOIN location_station_keys k ON k.location_id=l.id WHERE l.active=1 ORDER BY l.name")->fetchAll();
?>
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Mac Station Key</title><style>
:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#0d1014;color:#f5f7fa;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}.wrap{max-width:900px;margin:0 auto;padding:28px 18px 60px}.top{display:flex;justify-content:space-between;gap:16px;align-items:center;margin-bottom:20px}.top a{color:#fff;text-decoration:none;background:#252c36;padding:11px 14px;border-radius:10px}.card{background:#171c23;border:1px solid #303845;border-radius:18px;padding:22px;margin:14px 0}.eyebrow{font-size:12px;font-weight:800;letter-spacing:.14em;color:#ff6a6a}h1{margin:6px 0 8px;font-size:30px}h2{margin:0 0 6px}.muted{color:#aab3bf;line-height:1.55}.row{display:grid;grid-template-columns:1fr auto;gap:16px;align-items:center;border-top:1px solid #2b323c;padding:16px 0}.row:first-child{border-top:0}.status{font-size:12px;color:#aab3bf}.btn{border:0;border-radius:10px;padding:11px 14px;font-weight:800;cursor:pointer;background:#ef5350;color:white}.btn.secondary{background:#303845}.flash{border-radius:12px;padding:13px 15px;margin:12px 0;background:#153522;border:1px solid #2c7a4a}.flash.bad{background:#3a1717;border-color:#8b3d3d}.key{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:22px;letter-spacing:.05em;background:#0a0d10;border:1px solid #465363;padding:16px;border-radius:12px;word-break:break-all;user-select:all}.warn{color:#ffd5a3}.actions{display:flex;gap:8px;flex-wrap:wrap}@media(max-width:650px){.row{grid-template-columns:1fr}.top{align-items:flex-start;flex-direction:column}.key{font-size:17px}}
</style></head><body><main class="wrap"><div class="top"><div><div class="eyebrow">CHURCH COMMUNICATIONS</div><h1>Permanent Mac Station Keys</h1><p class="muted">This replaces the Mac pairing system. A Station Key does not expire. The Mac stores it once and stays assigned to that location until you change or revoke the key.</p></div><a href="app/admin.php?tab=locations">← Locations</a></div>
<?php if($flash!==''):?><div class="flash <?=$flashType==='bad'?'bad':''?>"><?=sk_h($flash)?></div><?php endif;?>
<?php if($newKey!==''):?><section class="card"><h2><?=sk_h($newLocation)?> — New Station Key</h2><p class="warn"><strong>Copy this now.</strong> For security, the website stores only its hash and cannot show this exact key again.</p><div class="key" id="newkey"><?=sk_h($newKey)?></div><p class="muted">Open Mac Location Station 2.1.2 and paste this into <strong>Station Key</strong>.</p></section><?php endif;?>
<section class="card"><h2>Locations</h2><p class="muted">Generate a key for TECHBOOTH or any other room Mac. Generating a new key immediately replaces the old key for that location.</p>
<?php foreach($locations as $l):?><div class="row"><div><strong><?=sk_h((string)$l['name'])?></strong><div class="status"><?php if($l['created_at']):?>Station Key exists • last used <?=sk_h((string)($l['last_used_at']?:'never'))?><?php else:?>No Station Key yet<?php endif;?></div></div><div class="actions"><form method="post"><input type="hidden" name="csrf" value="<?=sk_h(sk_csrf())?>"><input type="hidden" name="location_id" value="<?=(int)$l['id']?>"><input type="hidden" name="action" value="generate"><button class="btn" type="submit"><?=$l['created_at']?'Replace Key':'Generate Key'?></button></form><?php if($l['created_at']):?><form method="post" onsubmit="return confirm('Revoke this Station Key? The Mac will stop connecting until a new key is entered.');"><input type="hidden" name="csrf" value="<?=sk_h(sk_csrf())?>"><input type="hidden" name="location_id" value="<?=(int)$l['id']?>"><input type="hidden" name="action" value="revoke"><button class="btn secondary" type="submit">Revoke</button></form><?php endif;?></div></div><?php endforeach;?>
</section></main></body></html>
