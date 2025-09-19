# =============================================================================
# Windows 스토리지 알림 클라이언트 (StorageMonitor.ps1)
# 폐쇄망 환경용 - 공유 폴더 이벤트 모니터링 및 알림
# =============================================================================

param(
    [string]$SharedPath = "\\server\shared\storage_events",
    [int]$CheckIntervalSeconds = 300,  # 5분
    [string]$ProcessedEventsFile = "$env:TEMP\processed_events.txt"
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 전역 변수
$script:ProcessedEvents = @{}
$script:IsRunning = $true
$script:LogFile = "$env:TEMP\storage_monitor_client.log"

# 로그 함수
function Write-Log {
    param($Message, $Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Host $logMessage
    Add-Content -Path $script:LogFile -Value $logMessage
}

# 처리된 이벤트 가져오기
function Get-ProcessedEvents {
    if (Test-Path $ProcessedEventsFile) {
        try {
            $content = Get-Content $ProcessedEventsFile | ConvertFrom-Json
            foreach ($item in $content) {
                $script:ProcessedEvents[$item.event_id] = $item.timestamp
            }
            Write-Log "처리된 이벤트 $($script:ProcessedEvents.Count)개 로드"
        }
        catch {
            Write-Log "처리된 이벤트 파일 로드 실패: $($_.Exception.Message)" "ERROR"
        }
    }
}

# 처리된 이벤트 저장
function Save-ProcessedEvents {
    try {
        $events = @()
        foreach ($eventId in $script:ProcessedEvents.Keys) {
            $events += @{
                event_id = $eventId
                timestamp = $script:ProcessedEvents[$eventId]
            }
        }
        $events | ConvertTo-Json | Set-Content $ProcessedEventsFile
    }
    catch {
        Write-Log "처리된 이벤트 저장 실패: $($_.Exception.Message)" "ERROR"
    }
}

# Windows 알림 토스트 생성
function Show-WindowsToast {
    param(
        [string]$Title,
        [string]$Message,
        [string]$Severity = "INFO"
    )
    
    # 심각도별 아이콘 설정
    $balloonIcon = switch ($Severity) {
        "CRITICAL" { [System.Windows.Forms.MessageBoxIcon]::Error }
        "WARNING"  { [System.Windows.Forms.MessageBoxIcon]::Warning }
        default    { [System.Windows.Forms.MessageBoxIcon]::Information }
    }
    
    # 시스템 트레이 알림
    try {
        $notification = New-Object System.Windows.Forms.NotifyIcon
        $notification.Icon = [System.Drawing.SystemIcons]::Application
        $notification.BalloonTipIcon = $balloonIcon
        $notification.BalloonTipText = $Message
        $notification.BalloonTipTitle = $Title
        $notification.Visible = $true
        $notification.ShowBalloonTip(10000)  # 10초간 표시
        
        # 2초 후 정리
        Start-Sleep -Seconds 2
        $notification.Dispose()
    }
    catch {
        # 트레이 알림 실패시 메시지박스로 대체
        [System.Windows.Forms.MessageBox]::Show($Message, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, $balloonIcon)
    }
}

# PowerShell 팝업 알림
function Show-PowerShellPopup {
    param(
        [string]$Title,
        [string]$Message,
        [string]$Severity = "INFO"
    )
    
    $popup.Icon = switch ($Severity) {
        "CRITICAL" { "Error" }
        "WARNING"  { "Warning" }
        default    { "Information" }
    }
    
    # 별도 창으로 팝업 표시
    $popup = New-Object -ComObject Wscript.Shell
    $popup.Popup($Message, 0, $Title, 16)  # 16 = OK 버튼만
}

# 이벤트 파일 읽기 및 파싱
function Get-StorageEvents {
    param([string]$FilePath)
    
    $eventList = @()
    
    try {
        if (Test-Path $FilePath) {
            $lines = Get-Content $FilePath
            foreach ($line in $lines) {
                if ($line.Trim() -ne "") {
                    try {
                        $storageEvent = $line | ConvertFrom-Json
                        $eventList += $storageEvent
                    }
                    catch {
                        Write-Log "이벤트 파싱 실패: $line" "WARNING"
                    }
                }
            }
        }
    }
    catch {
        Write-Log "이벤트 파일 읽기 실패: $($_.Exception.Message)" "ERROR"
    }
    
    return $eventList
}

# 새 이벤트 처리
function Invoke-NewEventProcessing {
    param([array]$Events)
    
    $newEventCount = 0
    
    foreach ($storageEvent in $Events) {
        if (-not $script:ProcessedEvents.ContainsKey($storageEvent.event_id)) {
            # 새 이벤트 발견
            $script:ProcessedEvents[$storageEvent.event_id] = $storageEvent.timestamp
            $newEventCount++
            
            # 알림 표시
            $title = "스토리지 경고 - $($storageEvent.source)"
            $message = "$($storageEvent.message)`n시간: $($storageEvent.timestamp)`n유형: $($storageEvent.type)"
            
            Write-Log "새 이벤트 알림: $($storageEvent.severity) - $($storageEvent.message)"
            
            # Windows 토스트 알림
            Show-WindowsToast -Title $title -Message $message -Severity $storageEvent.severity
            
            # CRITICAL 이벤트는 추가로 팝업도 표시
            if ($storageEvent.severity -eq "CRITICAL") {
                Show-PowerShellPopup -Title $title -Message $message -Severity $storageEvent.severity
            }
            
            # 잠깐 대기 (연속 알림 방지)
            Start-Sleep -Seconds 1
        }
    }
    
    if ($newEventCount -gt 0) {
        Write-Log "새 이벤트 $newEventCount 개 처리 완료"
        Save-ProcessedEvents
    }
}

# 공유 폴더 모니터링
function Start-StorageMonitoring {
    Write-Log "=== 스토리지 모니터링 클라이언트 시작 ==="
    Write-Log "공유 경로: $SharedPath"
    Write-Log "체크 주기: $CheckIntervalSeconds 초"
    
    Get-ProcessedEvents
    
    while ($script:IsRunning) {
        try {
            # 오늘 이벤트 파일 확인
            $today = Get-Date -Format "yyyyMMdd"
            $eventFile = Join-Path $SharedPath "events_$today.json"
            
            if (Test-Path $eventFile) {
            if (Test-Path $eventFile) {
                $eventList = Get-StorageEvents -FilePath $eventFile
                if ($eventList.Count -gt 0) {
                    Invoke-NewEventProcessing -Events $eventList
                }
            } else {
                Write-Log "이벤트 파일 없음: $eventFile" "DEBUG"
            }
            
            # 어제 이벤트도 확인 (자정 근처 누락 방지)
            $yesterday = (Get-Date).AddDays(-1).ToString("yyyyMMdd")
            $yesterdayFile = Join-Path $SharedPath "events_$yesterday.json"
            if (Test-Path $yesterdayFile) {
                $eventList = Get-StorageEvents -FilePath $yesterdayFile
                if ($eventList.Count -gt 0) {
                    Invoke-NewEventProcessing -Events $eventList
                }
            }
            } else {
                Write-Log "이벤트 파일 없음: $eventFile" "DEBUG"
            }
            
            # 어제 이벤트도 확인 (자정 근처 누락 방지)
            $yesterday = (Get-Date).AddDays(-1).ToString("yyyyMMdd")
            $yesterdayFile = Join-Path $SharedPath "events_$yesterday.json"
            if (Test-Path $yesterdayFile) {
                $events = Get-StorageEvents -FilePath $yesterdayFile
                if ($events.Count -gt 0) {
                    Process-NewEvents -Events $events
                }
            }
            
        }
        catch {
            Write-Log "모니터링 중 오류: $($_.Exception.Message)" "ERROR"
        }
        
        # 대기
        Start-Sleep -Seconds $CheckIntervalSeconds
    }
}

# 일일 요약 리포트 생성
function New-DailyReport {
    $today = Get-Date -Format "yyyyMMdd"
    $eventFile = Join-Path $SharedPath "events_$today.json"
    
    if (Test-Path $eventFile) {
        $eventList = Get-StorageEvents -FilePath $eventFile
        
        $criticalCount = ($eventList | Where-Object { $_.severity -eq "CRITICAL" }).Count
        $warningCount = ($eventList | Where-Object { $_.severity -eq "WARNING" }).Count
        
        $reportMessage = @"
=== 일일 스토리지 모니터링 요약 ===
날짜: $(Get-Date -Format "yyyy-MM-dd")
총 이벤트: $($eventList.Count)
위험 이벤트: $criticalCount
경고 이벤트: $warningCount

최근 이벤트:
$($eventList | Select-Object -Last 5 | ForEach-Object { "- $($_.timestamp): $($_.message)" } | Out-String)
"@

        Write-Log $reportMessage
        Show-WindowsToast -Title "일일 스토리지 리포트" -Message "위험 $criticalCount건, 경고 $warningCount건"
    }
}

# Ctrl+C 핸들러
[Console]::TreatControlCAsInput = $false
[Console]::CancelKeyPress += {
    Write-Log "종료 신호 수신, 정리 중..."
    $script:IsRunning = $false
    Save-ProcessedEvents
}

# 메인 실행
try {
    # 관리자 권한 확인
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "관리자 권한으로 실행하는 것을 권장합니다" "WARNING"
    }
    
    # 공유 폴더 접근 테스트
    if (-not (Test-Path $SharedPath)) {
        Write-Log "공유 폴더에 접근할 수 없습니다: $SharedPath" "ERROR"
        Write-Log "네트워크 연결 및 권한을 확인하세요" "ERROR"
        exit 1
    }
    
    Write-Log "스토리지 모니터링 클라이언트가 시작되었습니다"
    Write-Log "종료하려면 Ctrl+C를 누르세요"
    
    # 시작 알림
    Show-WindowsToast -Title "스토리지 모니터" -Message "모니터링이 시작되었습니다"
    
    # 모니터링 시작
    Start-StorageMonitoring
}
catch {
    Write-Log "클라이언트 실행 중 오류: $($_.Exception.Message)" "ERROR"
}
finally {
    Write-Log "=== 스토리지 모니터링 클라이언트 종료 ==="
}