# Live board bridge (data-in-URL, 2-board layout) with HOST FAILOVER.
# Reads the in-world game hover boards (TT_OrderBoard_Main + TT_Scoreboard_Main)
# and bakes their COMBINED data into the single OPERATIONS board's media URL
# (ops.html?d=base64 JSON {orders,score}). 2026-07-06: the GUEST board is now LIVE
# too — fed from TT_EventCampaigns + TT_RatingTerminal + TT_StaffRoster hovertext
# (guest.html?d=base64 {event,rating,roster}). NO cloud store.
# Primary host = Vercel; fails over to the GitHub Pages mirror if Vercel is down.
# Run with pwsh.
$ErrorActionPreference = 'SilentlyContinue'
$base    = 'http://127.0.0.1:8797'
$vercel  = 'https://tt-boards.vercel.app'
$ghpages = 'https://sweetluvianto.github.io/tt-boards'
$OPS_ID  = '049f6d6a-2dfb-dd0a-2518-8c4bacf8f3df'   # TT_Board_OPERATIONS (new venue Saint Louis Isle, 2026-06-29)
$GUEST_ID = 'd14a6bb1-5ed8-cd1d-f2c9-34c18067ab46'  # TT_Board_GUEST

function Get-Hdr {
  $sess = Get-Content "$env:LOCALAPPDATA\Verve\FirestormDevBridge\session.json" -Raw | ConvertFrom-Json
  $tok  = ConvertTo-SecureString $sess.tokenProtected | ConvertFrom-SecureString -AsPlainText
  @{ Authorization = "Bearer $tok" }
}
function Read-Text($hdr,$id){ ((Invoke-WebRequest -Uri "$base/objects/text?objectId=$id" -Headers $hdr -TimeoutSec 12 -UseBasicParsing).Content | ConvertFrom-Json).text }
function B64Url($obj){ [uri]::EscapeDataString([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Compress -Depth 8)))) }
function Set-BoardUrl($hdr,$id,$site,$page,$obj){
  $u = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $url = "$site/$page`?d=$(B64Url $obj)"
  Invoke-WebRequest -Uri "$base/objects/media?objectId=$id&face=all&url=$([uri]::EscapeDataString($url))&autoScale=true&mediaWidth=2048&mediaHeight=1024&allowMedia=true&confirm=true&runId=b$u&prefix=TT_" -Method POST -Headers $hdr -TimeoutSec 20 -UseBasicParsing | Out-Null
}

Write-Host "tt board bridge (2-board ops+guest, data-in-url + failover) running (Ctrl+C to stop)"
$cycle = 0; $lastOps = ''; $lastGuest = ''; $site = $vercel
while ($true) {
  try {
    $hdr = Get-Hdr
    if ($cycle % 6 -eq 0) {
      $new = $vercel
      try { $r = Invoke-WebRequest "$vercel/ops.html" -Method Head -TimeoutSec 6 -UseBasicParsing; if ($r.StatusCode -ne 200) { $new = $ghpages } } catch { $new = $ghpages }
      if ($new -ne $site) { $site = $new; $lastOps = ''; Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] host failover -> $site" }
    }
    # requestFetch=true forces a FRESH property/hovertext fetch from the sim — without it
    # /objects/text below reads a stale viewer cache and live orders never reach the web board.
    $near = ((Invoke-WebRequest -Uri "$base/objects/nearby?radius=128&resolve=true&requestFetch=true" -Headers $hdr -TimeoutSec 30 -UseBasicParsing).Content | ConvertFrom-Json).objects
    Start-Sleep -Milliseconds 1500
    $ob = $near | Where-Object { $_.name -eq 'TT_OrderBoard_Main' } | Select-Object -First 1
    $sb = $near | Where-Object { $_.name -eq 'TT_Scoreboard_Main' } | Select-Object -First 1

    if ($ob -and $sb) {
      # orders
      $t = Read-Text $hdr $ob.objectId
      $rows = @(); $i = 0
      foreach ($l in ($t -split "`n" | Select-Object -Skip 1)) {
        if ($l -match '\|') { $p = $l -split '\s*\|\s*'; $i++; $item = ($p[3] -replace '_',' '); $rows += @{ id = "#$i"; pax = ("$($p[1]) - $item"); time = $p[4] } }
      }
      if ($rows.Count -eq 0) { $rows = @(@{ id=''; pax='No active orders'; time='' }) }
      # score
      $t2 = Read-Text $hdr $sb.objectId
      $sl = $t2 -split "`n"
      $ev = (($sl | Where-Object { $_ -match '^Event:' }) -replace '^Event:\s*','') -join ''
      $mx = @()
      foreach ($k in 'Shift Score','Staff served','Loyalty guests') {
        $ln = $sl | Where-Object { $_ -match "^$([regex]::Escape($k))\s*:" } | Select-Object -First 1
        if ($ln) { $mx += @{ label=$k; value=(($ln -replace '^[^:]*:\s*','').Trim()) } }
      }
      $combined = @{ orders=@{ sections=@(@{ label='Active Orders'; icon='lock'; rows=$rows }) }; score=@{ event=$ev; metrics=$mx } }
      $cj = $combined | ConvertTo-Json -Compress -Depth 8
      if ($cj -ne $lastOps) { Set-BoardUrl $hdr $OPS_ID $site 'ops.html' $combined; $lastOps = $cj; Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] ops updated ($($rows.Count) orders)" }
    }

    # --- GUEST board (2026-07-06): Event + Rating + Roster from the in-world hovers ---
    $evb = $near | Where-Object { $_.name -eq 'TT_EventCampaigns' } | Select-Object -First 1
    $rtb = $near | Where-Object { $_.name -eq 'TT_RatingTerminal' } | Select-Object -First 1
    $srb = $near | Where-Object { $_.name -eq 'TT_StaffRoster' }   | Select-Object -First 1
    if ($evb -or $rtb -or $srb) {
      # event: hover "Active: <name>"
      $gevent = @{ title='A Quiet Evening'; desc='Walk-ins welcome - take a seat, tap the menu book, and let our waiter look after you.'; when='' }
      if ($evb) {
        $et = Read-Text $hdr $evb.objectId
        $el = ($et -split "`n" | Where-Object { $_ -match '^Active:\s*(.+)$' } | Select-Object -First 1)
        if ($el -and $el -match '^Active:\s*(.+)$') {
          $en = $Matches[1].Trim()
          if ($en -and $en -notmatch '^(none|-)$') { $gevent = @{ title=$en; desc='Happening tonight at Table & Tales - ask our staff for details.'; when='Now' } }
        }
      }
      # rating: hover "Last average: X/5 (N ratings)"
      $grating = @{ avg=[string][char]0x2014; stars=0; count='Be the first to rate!' }
      if ($rtb) {
        $rt = Read-Text $hdr $rtb.objectId
        if ($rt -match 'Last average:\s*(\d+)\s*/\s*5(?:\s*\((\d+)\s*ratings?\))?') {
          $av = [int]$Matches[1]; $cnt = $Matches[2]
          $cs = 'live guest ratings'; if ($cnt) { $cs = "$cnt ratings" }
          $grating = @{ avg="$av.0"; stars=$av; count=$cs }
        }
      }
      # roster: hover lines after the 2 header lines; "No staff clocked in" -> SOLO service
      $groster = @(@{ name='Self-service tonight'; role='SOLO'; on=$true })
      if ($srb) {
        $st = Read-Text $hdr $srb.objectId
        $sl2 = @($st -split "`n" | Select-Object -Skip 2 | Where-Object { $_.Trim() -ne '' -and $_ -notmatch 'No staff' })
        if ($sl2.Count -gt 0) {
          $groster = @()
          foreach ($ln in ($sl2 | Select-Object -First 6)) {
            $nm = $ln.Trim(); $rl = ''
            if ($nm -match '^(.*?)\s*[-—:]\s*(.+)$') { $nm = $Matches[1].Trim(); $rl = $Matches[2].Trim() }
            $groster += @{ name=$nm; role=$rl; on=$true }
          }
        }
      }
      $guest = @{ event=$gevent; rating=$grating; roster=$groster }
      $gj = $guest | ConvertTo-Json -Compress -Depth 8
      if ($gj -ne $lastGuest) { Set-BoardUrl $hdr $GUEST_ID $site 'guest.html' $guest; $lastGuest = $gj; Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] guest updated" }
    }

    $cycle++
    if ($false) {  # keep-alive TP DISABLED 2026-06-29 (old coords Shelter z1505 would TP avatar off the new Saint Louis Isle venue)
      $ru = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      try { Invoke-WebRequest -Uri "$base/avatar/teleport?regionName=Shelter&x=236&y=132&z=1505&allowTeleport=true&confirm=true&runId=ka$ru" -Method POST -Headers $hdr -TimeoutSec 15 -UseBasicParsing | Out-Null } catch {}
    }
    Remove-Variable tok -ErrorAction SilentlyContinue
  } catch {}
  Start-Sleep -Seconds 5
}
