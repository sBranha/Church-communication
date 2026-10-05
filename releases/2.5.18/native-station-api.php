<?php
declare(strict_types=1);
require_once __DIR__.'/lib/bootstrap.php';

header('Cache-Control: no-store, no-cache, must-revalidate');
header('Pragma: no-cache');

function helper_text(string $body,int $status=200): never {
    http_response_code($status);
    header('Content-Type: text/plain; charset=utf-8');
    echo $body;
    exit;
}
function helper_json(array $data,int $status=200): never {
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($data,JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE);
    exit;
}
function helper_field(string $value): string {
    $value=preg_replace('/[\r\n\t]+/u',' ',trim($value))??'';
    return function_exists('mb_substr')?mb_substr($value,0,2000):substr($value,0,2000);
}
function helper_payload(): array {
    $data=$_POST;
    $ct=strtolower((string)($_SERVER['CONTENT_TYPE']??''));
    if(str_contains($ct,'application/json')){
        $raw=file_get_contents('php://input');
        $j=json_decode((string)$raw,true);
        if(is_array($j))$data=array_merge($data,$j);
    }
    return $data;
}
function helper_device_schema(PDO $db): void {
    $db->exec("CREATE TABLE IF NOT EXISTS location_devices (id INTEGER PRIMARY KEY AUTOINCREMENT, location_id INTEGER NOT NULL, device_name TEXT NOT NULL DEFAULT '', device_type TEXT NOT NULL DEFAULT 'unknown', token_hash TEXT NOT NULL UNIQUE, app_version TEXT, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, last_seen_at TEXT, revoked_at TEXT, FOREIGN KEY(location_id) REFERENCES locations(id) ON DELETE CASCADE)");
    $db->exec("CREATE INDEX IF NOT EXISTS idx_location_devices_location_active ON location_devices(location_id,revoked_at)");
}
function helper_station_key_schema(PDO $db): void {
    $db->exec("CREATE TABLE IF NOT EXISTS location_station_keys (location_id INTEGER PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, rotated_at TEXT, last_used_at TEXT, FOREIGN KEY(location_id) REFERENCES locations(id) ON DELETE CASCADE)");
    $db->exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_location_station_keys_hash ON location_station_keys(token_hash)");
}
function helper_token(): string {
    $t=trim((string)($_SERVER['HTTP_X_CC_LOCATION_TOKEN']??''));
    if($t===''){
        $auth=trim((string)($_SERVER['HTTP_AUTHORIZATION']??''));
        if(preg_match('/^Bearer\s+(.+)$/i',$auth,$m))$t=trim((string)$m[1]);
    }
    if($t==='')$t=trim((string)($_POST['token']??$_GET['token']??''));
    return $t;
}
function helper_legacy_slot(PDO $db,int $locationId): int {
    $q=$db->prepare("SELECT CASE WHEN COALESCE(device_token_hash,'')<>'' THEN 1 ELSE 0 END FROM locations WHERE id=?");$q->execute([$locationId]);return (int)($q->fetchColumn()?:0);
}
function helper_device_count(PDO $db,int $locationId): int {
    $q=$db->prepare("SELECT count(*) FROM location_devices WHERE location_id=? AND revoked_at IS NULL");$q->execute([$locationId]);return (int)$q->fetchColumn()+helper_legacy_slot($db,$locationId);
}
function helper_identity(PDO $db): array {
    helper_device_schema($db);
    $token=helper_token();
    if($token==='') helper_json(['ok'=>false,'error'=>'Authentication required'],401);
    $hash=hash('sha256',$token);
    helper_station_key_schema($db);
    $q=$db->prepare("SELECT k.location_id id,l.name FROM location_station_keys k JOIN locations l ON l.id=k.location_id WHERE k.token_hash=? AND l.active=1 LIMIT 1");
    $q->execute([$hash]);$station=$q->fetch();
    if($station){
        $db->prepare('UPDATE location_station_keys SET last_used_at=CURRENT_TIMESTAMP WHERE location_id=?')->execute([(int)$station['id']]);
        $db->prepare('UPDATE locations SET last_seen_at=CURRENT_TIMESTAMP WHERE id=?')->execute([(int)$station['id']]);
        return ['type'=>'location','id'=>(int)$station['id'],'name'=>(string)$station['name'],'role'=>'location','device_id'=>-1,'legacy'=>false,'station_key'=>true,'device_name'=>'Permanent Station Key','device_type'=>'station_key'];
    }
    $q=$db->prepare("SELECT d.id device_id,d.location_id id,l.name,d.device_name,d.device_type FROM location_devices d JOIN locations l ON l.id=d.location_id WHERE d.token_hash=? AND d.revoked_at IS NULL AND l.active=1 LIMIT 1");
    $q->execute([$hash]);$row=$q->fetch();
    if($row){
        $db->prepare('UPDATE location_devices SET last_seen_at=CURRENT_TIMESTAMP WHERE id=?')->execute([(int)$row['device_id']]);
        $db->prepare('UPDATE locations SET last_seen_at=CURRENT_TIMESTAMP WHERE id=?')->execute([(int)$row['id']]);
        return ['type'=>'location','id'=>(int)$row['id'],'name'=>(string)$row['name'],'role'=>'location','device_id'=>(int)$row['device_id'],'legacy'=>false,'device_name'=>(string)$row['device_name'],'device_type'=>(string)$row['device_type']];
    }
    // Backward compatibility: keep one existing browser/iPad token as one of the five slots.
    $q=$db->prepare("SELECT id,name FROM locations WHERE device_token_hash=? AND active=1 LIMIT 1");$q->execute([$hash]);$row=$q->fetch();
    if(!$row) helper_json(['ok'=>false,'error'=>'This device is not paired or has been unpaired'],401);
    $db->prepare('UPDATE locations SET last_seen_at=CURRENT_TIMESTAMP WHERE id=?')->execute([(int)$row['id']]);
    return ['type'=>'location','id'=>(int)$row['id'],'name'=>(string)$row['name'],'role'=>'location','device_id'=>0,'legacy'=>true,'device_name'=>'Legacy room device','device_type'=>'browser'];
}
function helper_name(PDO $db,string $type,int $id): string {
    if($type==='location'){$q=$db->prepare('SELECT name FROM locations WHERE id=?');$q->execute([$id]);return (string)($q->fetchColumn()?:'Location');}
    $q=$db->prepare('SELECT display_name FROM users WHERE id=?');$q->execute([$id]);return (string)($q->fetchColumn()?:'Person');
}
function helper_user_allowed(PDO $db,int $locationId,int $userId): bool {
    $q=$db->prepare('SELECT role,active FROM users WHERE id=?');$q->execute([$userId]);$u=$q->fetch();
    if(!$u || !(int)$u['active']) return false;
    if(in_array((string)$u['role'],['admin','super_admin'],true)) return true;
    $q=$db->prepare('SELECT 1 FROM location_user_permissions WHERE location_id=? AND user_id=?');$q->execute([$locationId,$userId]);return (bool)$q->fetchColumn();
}
function helper_group_allowed(PDO $db,int $locationId,int $groupId): bool {
    $q=$db->prepare("SELECT 1 FROM groups g WHERE g.id=? AND g.active=1 AND EXISTS(SELECT 1 FROM location_group_permissions p WHERE p.location_id=? AND p.group_id=g.id)");
    $q->execute([$groupId,$locationId]);return (bool)$q->fetchColumn();
}
function helper_direct_authorized(PDO $db,int $locationId,int $threadId): bool {
    $mine=$db->prepare("SELECT 1 FROM thread_members WHERE thread_id=? AND member_type='location' AND member_id=?");$mine->execute([$threadId,$locationId]);if(!$mine->fetchColumn())return false;
    $m=$db->prepare("SELECT member_type,member_id FROM thread_members WHERE thread_id=? AND NOT(member_type='location' AND member_id=?)");
    $m->execute([$threadId,$locationId]);$others=$m->fetchAll();if(!$others)return false;
    foreach($others as $o){
        $type=(string)$o['member_type'];$id=(int)$o['member_id'];
        if($type==='location'){$q=$db->prepare('SELECT 1 FROM locations WHERE id=? AND active=1');$q->execute([$id]);if(!$q->fetchColumn())return false;}
        elseif($type==='user'){if(!helper_user_allowed($db,$locationId,$id))return false;}
        else return false;
    }
    return true;
}
function helper_thread(PDO $db,int $locationId,int $threadId): ?array {
    $q=$db->prepare('SELECT id,type,title,group_id,updated_at FROM threads WHERE id=?');$q->execute([$threadId]);$t=$q->fetch();if(!$t)return null;
    if((string)$t['type']==='group'){
        $gid=(int)($t['group_id']??0);if(!$gid||!helper_group_allowed($db,$locationId,$gid))return null;
    } elseif((string)$t['type']==='direct') { if(!helper_direct_authorized($db,$locationId,$threadId))return null; }
    else return null;
    $t['id']=(int)$t['id'];$t['group_id']=$t['group_id']!==null?(int)$t['group_id']:null;
    return $t;
}
function helper_thread_title(PDO $db,int $locationId,array $t): string {
    if((string)$t['type']==='group' && !empty($t['group_id'])){$q=$db->prepare('SELECT name FROM groups WHERE id=?');$q->execute([(int)$t['group_id']]);return (string)($q->fetchColumn()?:$t['title']?:'Room');}
    $q=$db->prepare("SELECT member_type,member_id FROM thread_members WHERE thread_id=? AND NOT(member_type='location' AND member_id=?) ORDER BY rowid LIMIT 4");$q->execute([(int)$t['id'],$locationId]);$names=[];foreach($q->fetchAll() as $m)$names[]=helper_name($db,(string)$m['member_type'],(int)$m['member_id']);return $names?implode(', ',$names):(string)($t['title']?:'Conversation');
}
function helper_touch_read(PDO $db,int $threadId,int $locationId,int $messageId): void {
    $db->prepare("INSERT INTO read_receipts(thread_id,member_type,member_id,last_read_message_id,updated_at) VALUES(?,'location',?,?,CURRENT_TIMESTAMP) ON CONFLICT(thread_id,member_type,member_id) DO UPDATE SET last_read_message_id=CASE WHEN excluded.last_read_message_id>read_receipts.last_read_message_id THEN excluded.last_read_message_id ELSE read_receipts.last_read_message_id END,updated_at=CURRENT_TIMESTAMP")->execute([$threadId,$locationId,$messageId]);
}
function helper_pair_claim(PDO $db,string $rawCode,array $meta=[]): array {
    helper_device_schema($db);
    $code=preg_replace('/\D/','',$rawCode)??'';
    if(strlen($code)!==8)return ['ok'=>false,'status'=>422,'error'=>'Enter the 8-digit pairing code shown in Admin → Locations'];
    $hash=hash('sha256',$code);
    $q=$db->prepare("SELECT id,name FROM locations WHERE pairing_code_hash=? AND pairing_expires_at>datetime('now') AND active=1 LIMIT 1");
    $q->execute([$hash]);$loc=$q->fetch();
    if(!$loc)return ['ok'=>false,'status'=>403,'error'=>'That pairing code is invalid or expired'];
    $locationId=(int)$loc['id'];
    $used=helper_device_count($db,$locationId);
    if($used>=5)return ['ok'=>false,'status'=>409,'error'=>'This location already has 5 paired devices. Unpair one device before adding another.','slots_used'=>$used,'max_devices'=>5];
    $deviceName=helper_field((string)($meta['device_name']??'Location device')); if($deviceName==='')$deviceName='Location device';
    $deviceType=helper_field((string)($meta['device_type']??'unknown')); if($deviceType==='')$deviceType='unknown';
    $appVersion=helper_field((string)($meta['app_version']??''));
    $token=bin2hex(random_bytes(32));$tokenHash=hash('sha256',$token);
    $db->beginTransaction();
    try{
        $db->prepare("INSERT INTO location_devices(location_id,device_name,device_type,token_hash,app_version,last_seen_at) VALUES(?,?,?,?,?,CURRENT_TIMESTAMP)")->execute([$locationId,$deviceName,$deviceType,$tokenHash,$appVersion]);
        $deviceId=(int)$db->lastInsertId();
        $db->prepare("UPDATE locations SET pairing_code_hash=NULL,pairing_expires_at=NULL,paired_at=COALESCE(paired_at,CURRENT_TIMESTAMP),last_seen_at=CURRENT_TIMESTAMP WHERE id=?")->execute([$locationId]);
        $db->commit();
    }catch(Throwable $e){if($db->inTransaction())$db->rollBack();throw $e;}
    return ['ok'=>true,'status'=>200,'token'=>$token,'device_token'=>$token,'device_id'=>$deviceId,'location'=>helper_field((string)$loc['name']),'location_name'=>helper_field((string)$loc['name']),'location_id'=>$locationId,'slots_used'=>$used+1,'max_devices'=>5];
}

function helper_sync_group_thread(PDO $db,int $threadId,int $groupId): void {
    $g=$db->prepare('SELECT COALESCE(is_church_wide,0) FROM groups WHERE id=? AND active=1');$g->execute([$groupId]);$wide=(int)($g->fetchColumn()?:0);
    if($wide){
        foreach($db->query('SELECT id FROM users WHERE active=1')->fetchAll() as $u)$db->prepare("INSERT OR IGNORE INTO thread_members(thread_id,member_type,member_id) VALUES(?,'user',?)")->execute([$threadId,(int)$u['id']]);
        foreach($db->query('SELECT id FROM locations WHERE active=1')->fetchAll() as $l)$db->prepare("INSERT OR IGNORE INTO thread_members(thread_id,member_type,member_id) VALUES(?,'location',?)")->execute([$threadId,(int)$l['id']]);
    } else {
        $q=$db->prepare('SELECT member_type,member_id FROM group_members WHERE group_id=?');$q->execute([$groupId]);foreach($q->fetchAll() as $m)$db->prepare('INSERT OR IGNORE INTO thread_members(thread_id,member_type,member_id) VALUES(?,?,?)')->execute([$threadId,(string)$m['member_type'],(int)$m['member_id']]);
    }
}
function helper_push_message(PDO $db,array $me,int $messageId,int $threadId,string $body,string $priority): void {
    if(!function_exists('cc_push_to_identity'))return;
    $q=$db->prepare('SELECT member_type,member_id FROM thread_members WHERE thread_id=? AND NOT(member_type=? AND member_id=?)');$q->execute([$threadId,$me['type'],$me['id']]);
    $payload=['title'=>helper_name($db,$me['type'],(int)$me['id']),'body'=>(function_exists('mb_substr')?mb_substr($body,0,180):substr($body,0,180)),'url'=>'index.php?thread='.$threadId,'priority'=>$priority,'tag'=>'cc-message-'.$messageId,'message_id'=>$messageId,'thread_id'=>$threadId];
    foreach($q->fetchAll() as $m){try{cc_push_to_identity((string)$m['member_type'],(int)$m['member_id'],$payload);}catch(Throwable $e){}}
}

$db=cc_db();
helper_device_schema($db);
helper_station_key_schema($db);
$payload=helper_payload();
$action=(string)($_GET['action']??$payload['action']??'poll');

if($action==='ping')helper_json(['ok'=>true,'service'=>'church-communications-location','api_version'=>'2.5.18-station-key']);

if(in_array($action,['pair','pair_json','claim_setup','claim-setup','pair_device'],true)){
    $wantsJson=$action!=='pair';
    if($_SERVER['REQUEST_METHOD']!=='POST'){
        if($wantsJson)helper_json(['ok'=>false,'error'=>'POST required','api_version'=>'2.5.18-station-key'],405);
        helper_text("error\tPOST required\n",405);
    }
    try{
        $r=helper_pair_claim($db,(string)($payload['code']??''),$payload);
        if($wantsJson){
            $status=(int)$r['status'];unset($r['status']);$r['api_version']='2.5.18';helper_json($r,$status);
        }
        if(empty($r['ok']))helper_text("error\t".$r['error']."\n",(int)$r['status']);
        helper_text("ok\t".$r['token']."\t".helper_field((string)$r['location'])."\n");
    }catch(Throwable $e){
        if($wantsJson)helper_json(['ok'=>false,'error'=>'Pairing server error','detail'=>$e->getMessage(),'api_version'=>'2.5.18-station-key'],500);
        helper_text("error\tPairing server error\n",500);
    }
}

$me=helper_identity($db);$locationId=(int)$me['id'];


if($action==='unpair_self'){
    if($_SERVER['REQUEST_METHOD']!=='POST')helper_json(['ok'=>false,'error'=>'POST required'],405);
    if(!empty($me['station_key'])) helper_json(['ok'=>true,'location_id'=>$locationId,'station_key_preserved'=>true]);
    if(!empty($me['legacy'])){
        $db->prepare("UPDATE locations SET device_token_hash=NULL WHERE id=?")->execute([$locationId]);
        $db->prepare("DELETE FROM push_subscriptions WHERE member_type='location' AND member_id=?")->execute([$locationId]);
    }else{
        $db->prepare("UPDATE location_devices SET revoked_at=CURRENT_TIMESTAMP WHERE id=? AND location_id=?")->execute([(int)$me['device_id'],$locationId]);
    }
    helper_json(['ok'=>true,'location_id'=>$locationId]);
}
if($action==='device_status'){
    $q=$db->prepare("SELECT id,device_name,device_type,app_version,created_at,last_seen_at FROM location_devices WHERE location_id=? AND revoked_at IS NULL ORDER BY created_at,id");$q->execute([$locationId]);$devices=$q->fetchAll();
    if(helper_legacy_slot($db,$locationId))array_unshift($devices,['id'=>0,'device_name'=>'Legacy room device','device_type'=>'browser','app_version'=>'','created_at'=>null,'last_seen_at'=>null]);
    helper_json(['ok'=>true,'location_id'=>$locationId,'location_name'=>$me['name'],'devices'=>$devices,'slots_used'=>count($devices),'max_devices'=>5,'auth_mode'=>!empty($me['station_key'])?'station_key':(!empty($me['legacy'])?'legacy':'device_token')]);
}

// Compatibility API used by the native Mac/Windows station clients.
if($action==='station_threads'){
    $q=$db->prepare("SELECT DISTINCT t.id,t.type,t.title,t.group_id,t.updated_at FROM threads t LEFT JOIN thread_members tm ON tm.thread_id=t.id WHERE (tm.member_type='location' AND tm.member_id=?) OR (t.type='group' AND EXISTS(SELECT 1 FROM location_group_permissions p WHERE p.location_id=? AND p.group_id=t.group_id)) ORDER BY t.updated_at DESC LIMIT 120");$q->execute([$locationId,$locationId]);
    $rows=[];foreach($q->fetchAll() as $t){$t['id']=(int)$t['id'];$t['group_id']=$t['group_id']!==null?(int)$t['group_id']:null;if(!helper_thread($db,$locationId,(int)$t['id']))continue;$name=helper_thread_title($db,$locationId,$t);$where=((string)$t['type']==='direct')?" AND created_at>=datetime('now','-2 hours')":'';$m=$db->prepare("SELECT body,created_at FROM messages WHERE thread_id=? AND (deleted_at IS NULL OR deleted_at='')".$where." ORDER BY id DESC LIMIT 1");$m->execute([(int)$t['id']]);$last=$m->fetch();$rows[]=['id'=>(int)$t['id'],'name'=>$name,'preview'=>$last?(string)$last['body']:'','updated_at'=>$last?(string)$last['created_at']:(string)$t['updated_at'],'type'=>(string)$t['type']];}
    helper_json(['ok'=>true,'threads'=>$rows]);
}
if($action==='station_messages'){
    $tid=max(0,(int)($_GET['thread']??$_POST['thread']??0));$t=helper_thread($db,$locationId,$tid);if(!$t)helper_json(['ok'=>false,'error'=>'Conversation not available'],403);$where=((string)$t['type']==='direct')?" AND created_at>=datetime('now','-2 hours')":'';$q=$db->prepare("SELECT id,sender_type,sender_id,body,priority,created_at FROM messages WHERE thread_id=? AND (deleted_at IS NULL OR deleted_at='')".$where." ORDER BY id ASC LIMIT 200");$q->execute([$tid]);$rows=[];$last=0;foreach($q->fetchAll() as $m){$id=(int)$m['id'];$last=max($last,$id);$rows[]=['id'=>$id,'sender'=>helper_name($db,(string)$m['sender_type'],(int)$m['sender_id']),'message'=>(string)$m['body'],'priority'=>(string)$m['priority'],'time'=>(string)$m['created_at'],'mine'=>((string)$m['sender_type']==='location'&&(int)$m['sender_id']===$locationId)];}if($last>0)helper_touch_read($db,$tid,$locationId,$last);helper_json(['ok'=>true,'messages'=>$rows]);
}
if($action==='station_send'){
    if($_SERVER['REQUEST_METHOD']!=='POST')helper_json(['ok'=>false,'error'=>'POST required'],405);$tid=max(0,(int)($_POST['thread']??0));$t=helper_thread($db,$locationId,$tid);if(!$t)helper_json(['ok'=>false,'error'=>'Conversation not available'],403);$body=trim((string)($_POST['message']??''));if($body==='')helper_json(['ok'=>false,'error'=>'Message is blank'],422);if(mb_strlen($body)>2000)helper_json(['ok'=>false,'error'=>'Message is too long'],422);$priority=(string)($_POST['priority']??'normal');if(!in_array($priority,['normal','important','urgent'],true))$priority='normal';$db->prepare("INSERT INTO messages(thread_id,sender_type,sender_id,body,priority) VALUES(?,'location',?,?,?)")->execute([$tid,$locationId,$body,$priority]);$mid=(int)$db->lastInsertId();$db->prepare('UPDATE threads SET updated_at=CURRENT_TIMESTAMP WHERE id=?')->execute([$tid]);helper_touch_read($db,$tid,$locationId,$mid);helper_push_message($db,$me,$mid,$tid,$body,$priority);helper_json(['ok'=>true,'message_id'=>$mid]);
}
if($action==='station_recipients'){
    $q=$db->prepare("SELECT id,name FROM locations WHERE active=1 AND id<>? ORDER BY name");$q->execute([$locationId]);$rows=[];foreach($q->fetchAll() as $r)$rows[]=['id'=>(int)$r['id'],'name'=>(string)$r['name']];helper_json(['ok'=>true,'recipients'=>$rows]);
}
if($action==='station_new_message'){
    if($_SERVER['REQUEST_METHOD']!=='POST')helper_json(['ok'=>false,'error'=>'POST required'],405);$other=max(0,(int)($_POST['recipient']??0));$body=trim((string)($_POST['message']??''));if(!$other||$body==='')helper_json(['ok'=>false,'error'=>'Choose a location and enter a message'],422);$q=$db->prepare('SELECT 1 FROM locations WHERE id=? AND active=1 AND id<>?');$q->execute([$other,$locationId]);if(!$q->fetchColumn())helper_json(['ok'=>false,'error'=>'That location is not available'],404);$q=$db->prepare("SELECT t.id FROM threads t WHERE t.type='direct' AND EXISTS(SELECT 1 FROM thread_members a WHERE a.thread_id=t.id AND a.member_type='location' AND a.member_id=?) AND EXISTS(SELECT 1 FROM thread_members b WHERE b.thread_id=t.id AND b.member_type='location' AND b.member_id=?) AND (SELECT count(*) FROM thread_members c WHERE c.thread_id=t.id)=2 LIMIT 1");$q->execute([$locationId,$other]);$tid=(int)($q->fetchColumn()?:0);if(!$tid){$title=helper_name($db,'location',$other);$db->prepare("INSERT INTO threads(type,title,created_by_type,created_by_id) VALUES('direct',?,'location',?)")->execute([$title,$locationId]);$tid=(int)$db->lastInsertId();$ins=$db->prepare('INSERT INTO thread_members(thread_id,member_type,member_id) VALUES(?,?,?)');$ins->execute([$tid,'location',$locationId]);$ins->execute([$tid,'location',$other]);}$db->prepare("INSERT INTO messages(thread_id,sender_type,sender_id,body,priority) VALUES(?,'location',?,?,'normal')")->execute([$tid,$locationId,$body]);$mid=(int)$db->lastInsertId();$db->prepare('UPDATE threads SET updated_at=CURRENT_TIMESTAMP WHERE id=?')->execute([$tid]);helper_touch_read($db,$tid,$locationId,$mid);helper_push_message($db,$me,$mid,$tid,$body,'normal');helper_json(['ok'=>true,'thread_id'=>$tid,'message_id'=>$mid]);
}
if($action==='station_alerts'){
    $after=max(0,(int)($_GET['after']??0));$q=$db->prepare("SELECT m.id,m.thread_id,m.sender_type,m.sender_id,m.body,m.priority,m.created_at FROM messages m JOIN threads t ON t.id=m.thread_id JOIN thread_members tm ON tm.thread_id=m.thread_id WHERE t.type='direct' AND tm.member_type='location' AND tm.member_id=? AND m.id>? AND m.created_at>=datetime('now','-2 hours') AND (m.deleted_at IS NULL OR m.deleted_at='') AND NOT(m.sender_type='location' AND m.sender_id=?) ORDER BY m.id ASC LIMIT 50");$q->execute([$locationId,$after,$locationId]);$alerts=[];$cursor=$after;foreach($q->fetchAll() as $r){$tid=(int)$r['thread_id'];if(!helper_direct_authorized($db,$locationId,$tid))continue;$cursor=max($cursor,(int)$r['id']);$alerts[]=['id'=>(int)$r['id'],'thread'=>$tid,'sender'=>helper_name($db,(string)$r['sender_type'],(int)$r['sender_id']),'message'=>(string)$r['body'],'priority'=>(string)$r['priority'],'created_at'=>(string)$r['created_at'],'direct_to_location'=>true];}helper_json(['ok'=>true,'alerts'=>$alerts,'cursor'=>$cursor]);
}

if($action==='app_targets'){
    $targets=[];
    $q=$db->prepare("SELECT id,name FROM locations WHERE active=1 AND id<>? ORDER BY name");$q->execute([$locationId]);foreach($q->fetchAll() as $r)$targets[]=['type'=>'location','id'=>(int)$r['id'],'name'=>(string)$r['name'],'label'=>'Location'];
    $q=$db->prepare("SELECT u.id,u.display_name name FROM users u WHERE u.active=1 AND (u.role IN ('admin','super_admin') OR EXISTS(SELECT 1 FROM location_user_permissions p WHERE p.location_id=? AND p.user_id=u.id)) ORDER BY u.display_name");$q->execute([$locationId]);foreach($q->fetchAll() as $r)$targets[]=['type'=>'user','id'=>(int)$r['id'],'name'=>(string)$r['name'],'label'=>'Person'];
    $q=$db->prepare("SELECT g.id,g.name FROM groups g WHERE g.active=1 AND EXISTS(SELECT 1 FROM location_group_permissions p WHERE p.location_id=? AND p.group_id=g.id) ORDER BY g.name");$q->execute([$locationId]);foreach($q->fetchAll() as $r)$targets[]=['type'=>'group','id'=>(int)$r['id'],'name'=>(string)$r['name'],'label'=>'Room'];
    helper_json(['ok'=>true,'targets'=>$targets]);
}

if($action==='app_threads'){
    $q=$db->prepare("SELECT DISTINCT t.id,t.type,t.title,t.group_id,t.updated_at FROM threads t LEFT JOIN thread_members tm ON tm.thread_id=t.id WHERE (tm.member_type='location' AND tm.member_id=?) OR (t.type='group' AND EXISTS(SELECT 1 FROM location_group_permissions p WHERE p.location_id=? AND p.group_id=t.group_id)) ORDER BY t.updated_at DESC LIMIT 120");$q->execute([$locationId,$locationId]);
    $rows=[];foreach($q->fetchAll() as $t){$t['id']=(int)$t['id'];$t['group_id']=$t['group_id']!==null?(int)$t['group_id']:null;if(!helper_thread($db,$locationId,(int)$t['id']))continue;$t['title']=helper_thread_title($db,$locationId,$t);$where=((string)$t['type']==='direct')?" AND created_at>=datetime('now','-2 hours')":'';$m=$db->prepare("SELECT id,body,priority,created_at FROM messages WHERE thread_id=? AND (deleted_at IS NULL OR deleted_at='')".$where." ORDER BY id DESC LIMIT 1");$m->execute([(int)$t['id']]);$last=$m->fetch();$t['last_message']=$last?['id'=>(int)$last['id'],'body'=>(string)$last['body'],'priority'=>(string)$last['priority'],'created_at'=>(string)$last['created_at']]:null;$rows[]=$t;}
    helper_json(['ok'=>true,'threads'=>$rows]);
}

if($action==='app_messages'){
    $tid=max(0,(int)($_GET['thread_id']??$_POST['thread_id']??0));$t=helper_thread($db,$locationId,$tid);if(!$t)helper_json(['ok'=>false,'error'=>'Conversation not available'],403);
    $where=((string)$t['type']==='direct')?" AND created_at>=datetime('now','-2 hours')":'';$q=$db->prepare("SELECT id,sender_type,sender_id,body,priority,created_at FROM messages WHERE thread_id=? AND (deleted_at IS NULL OR deleted_at='')".$where." ORDER BY id ASC LIMIT 200");$q->execute([$tid]);$rows=[];$last=0;
    foreach($q->fetchAll() as $m){$id=(int)$m['id'];$last=max($last,$id);$rows[]=['id'=>$id,'sender_type'=>(string)$m['sender_type'],'sender_id'=>(int)$m['sender_id'],'sender_name'=>helper_name($db,(string)$m['sender_type'],(int)$m['sender_id']),'body'=>(string)$m['body'],'priority'=>(string)$m['priority'],'created_at'=>(string)$m['created_at'],'mine'=>((string)$m['sender_type']==='location'&&(int)$m['sender_id']===$locationId)];}
    if($last>0)helper_touch_read($db,$tid,$locationId,$last);$t['title']=helper_thread_title($db,$locationId,$t);helper_json(['ok'=>true,'thread'=>$t,'messages'=>$rows]);
}

if($action==='app_create_thread'){
    if($_SERVER['REQUEST_METHOD']!=='POST')helper_json(['ok'=>false,'error'=>'POST required'],405);$type=(string)($_POST['target_type']??'');$id=max(0,(int)($_POST['target_id']??0));if(!$id)helper_json(['ok'=>false,'error'=>'Choose a destination'],422);
    if($type==='group'){
        if(!helper_group_allowed($db,$locationId,$id))helper_json(['ok'=>false,'error'=>'That room is not authorized for this location'],403);$q=$db->prepare("SELECT id FROM threads WHERE type='group' AND group_id=? LIMIT 1");$q->execute([$id]);$tid=(int)($q->fetchColumn()?:0);if(!$tid){$n=$db->prepare('SELECT name FROM groups WHERE id=?');$n->execute([$id]);$title=(string)($n->fetchColumn()?:'Room');$db->prepare("INSERT INTO threads(type,title,group_id,created_by_type,created_by_id) VALUES('group',?,?, 'location',?)")->execute([$title,$id,$locationId]);$tid=(int)$db->lastInsertId();}helper_sync_group_thread($db,$tid,$id);$db->prepare("INSERT OR IGNORE INTO thread_members(thread_id,member_type,member_id) VALUES(?,'location',?)")->execute([$tid,$locationId]);helper_json(['ok'=>true,'thread_id'=>$tid]);
    }
    if(!in_array($type,['user','location'],true))helper_json(['ok'=>false,'error'=>'Invalid destination'],422);
    if($type==='user'&&!helper_user_allowed($db,$locationId,$id))helper_json(['ok'=>false,'error'=>'That person is not authorized for this location'],403);
    if($type==='location'){$q=$db->prepare('SELECT 1 FROM locations WHERE id=? AND active=1 AND id<>?');$q->execute([$id,$locationId]);if(!$q->fetchColumn())helper_json(['ok'=>false,'error'=>'That location is not available'],404);}
    $q=$db->prepare("SELECT t.id FROM threads t WHERE t.type='direct' AND EXISTS(SELECT 1 FROM thread_members a WHERE a.thread_id=t.id AND a.member_type='location' AND a.member_id=?) AND EXISTS(SELECT 1 FROM thread_members b WHERE b.thread_id=t.id AND b.member_type=? AND b.member_id=?) AND (SELECT count(*) FROM thread_members c WHERE c.thread_id=t.id)=2 LIMIT 1");$q->execute([$locationId,$type,$id]);$tid=(int)($q->fetchColumn()?:0);
    if(!$tid){$title=helper_name($db,$type,$id);$db->prepare("INSERT INTO threads(type,title,created_by_type,created_by_id) VALUES('direct',?,'location',?)")->execute([$title,$locationId]);$tid=(int)$db->lastInsertId();$ins=$db->prepare('INSERT INTO thread_members(thread_id,member_type,member_id) VALUES(?,?,?)');$ins->execute([$tid,'location',$locationId]);$ins->execute([$tid,$type,$id]);}
    helper_json(['ok'=>true,'thread_id'=>$tid]);
}

if($action==='app_send'){
    if($_SERVER['REQUEST_METHOD']!=='POST')helper_json(['ok'=>false,'error'=>'POST required'],405);$tid=max(0,(int)($_POST['thread_id']??0));$t=helper_thread($db,$locationId,$tid);if(!$t)helper_json(['ok'=>false,'error'=>'Conversation not available'],403);$body=trim((string)($_POST['body']??''));if($body==='')helper_json(['ok'=>false,'error'=>'Message is blank'],422);if(mb_strlen($body)>2000)helper_json(['ok'=>false,'error'=>'Message is too long'],422);$priority=(string)($_POST['priority']??'normal');if(!in_array($priority,['normal','important','urgent'],true))$priority='normal';
    $db->prepare("INSERT INTO messages(thread_id,sender_type,sender_id,body,priority) VALUES(?,'location',?,?,?)")->execute([$tid,$locationId,$body,$priority]);$mid=(int)$db->lastInsertId();$db->prepare('UPDATE threads SET updated_at=CURRENT_TIMESTAMP WHERE id=?')->execute([$tid]);helper_touch_read($db,$tid,$locationId,$mid);helper_push_message($db,$me,$mid,$tid,$body,$priority);helper_json(['ok'=>true,'message_id'=>$mid]);
}

if($action==='app_ack'){
    if($_SERVER['REQUEST_METHOD']!=='POST')helper_json(['ok'=>false,'error'=>'POST required'],405);$mid=max(0,(int)($_POST['message_id']??0));$q=$db->prepare('SELECT thread_id FROM messages WHERE id=?');$q->execute([$mid]);$tid=(int)($q->fetchColumn()?:0);if(!$tid||!helper_thread($db,$locationId,$tid))helper_json(['ok'=>false,'error'=>'Message not available'],404);$db->prepare("INSERT OR IGNORE INTO acknowledgements(message_id,member_type,member_id) VALUES(?,'location',?)")->execute([$mid,$locationId]);helper_touch_read($db,$tid,$locationId,$mid);helper_json(['ok'=>true]);
}

if($action==='poll'){
    $after=max(0,(int)($_GET['after_id']??0));
    $c=$db->prepare("SELECT COALESCE(MAX(m.id),0) FROM messages m JOIN threads t ON t.id=m.thread_id JOIN thread_members tm ON tm.thread_id=m.thread_id WHERE t.type='direct' AND tm.member_type='location' AND tm.member_id=?");$c->execute([$locationId]);$cursor=(int)$c->fetchColumn();
    $q=$db->prepare("SELECT m.id,m.thread_id,m.sender_type,m.sender_id,m.body,m.priority,m.created_at,t.title FROM messages m JOIN threads t ON t.id=m.thread_id JOIN thread_members tm ON tm.thread_id=m.thread_id WHERE t.type='direct' AND tm.member_type='location' AND tm.member_id=? AND m.id>? AND m.created_at>=datetime('now','-2 hours') AND (m.deleted_at IS NULL OR m.deleted_at='') AND NOT(m.sender_type='location' AND m.sender_id=?) ORDER BY m.id ASC LIMIT 25");$q->execute([$locationId,$after,$locationId]);$lines=[];
    foreach($q->fetchAll() as $r){$tid=(int)$r['thread_id'];if(!helper_direct_authorized($db,$locationId,$tid))continue;$sender=helper_name($db,(string)$r['sender_type'],(int)$r['sender_id']);$title=helper_thread_title($db,$locationId,['id'=>$tid,'type'=>'direct','title'=>$r['title'],'group_id'=>null]);$body=trim((string)$r['body']);if($body==='')$body='New message';$created=strtotime((string)$r['created_at'].' UTC');$ttl=max(1,min(7200,($created?:time())+7200-time()));$open=cc_base_url().'/index.php?thread='.$tid;$lines[]="message\t".(int)$r['id']."\t".$tid."\t".helper_field((string)$r['priority'])."\t".$ttl."\t".helper_field($sender)."\t".helper_field($title)."\t".helper_field($body)."\t".helper_field($open);}
    helper_text("cursor\t".$cursor."\n".($lines?implode("\n",$lines)."\n":''));
}

if($action==='ack'){
    if($_SERVER['REQUEST_METHOD']!=='POST')helper_text("error\tPOST required\n",405);$mid=max(0,(int)($_POST['message_id']??0));$q=$db->prepare('SELECT thread_id FROM messages WHERE id=?');$q->execute([$mid]);$tid=(int)($q->fetchColumn()?:0);if(!$tid||!helper_thread($db,$locationId,$tid))helper_text("error\tMessage not available\n",404);$db->prepare("INSERT OR IGNORE INTO acknowledgements(message_id,member_type,member_id) VALUES(?,'location',?)")->execute([$mid,$locationId]);helper_touch_read($db,$tid,$locationId,$mid);helper_text("ok\n");
}

helper_json(['ok'=>false,'error'=>'Unknown action'],404);
