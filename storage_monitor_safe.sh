#!/bin/bash
# storage_monitor_local_only_safe.sh
# macOS용 안전 버전 — 로컬 테스트용
# 모든 이벤트/로그는 $HOME/.storage_monitor 에만 기록됨

set -u

# ---------- 설정 ----------
SHARED_PATH="$HOME"       
STORAGE_NAME="storage-01"
EVENT_FILE_BASENAME="events"          
LOCAL_LOG_DIR="$HOME/.storage_monitor"
LOG_FILE="$LOCAL_LOG_DIR/storage_monitor.log"
DISK_CRITICAL=15
DISK_WARNING=10
IOWAIT_CRITICAL=3
MEMORY_CRITICAL=9
LOAD_CRITICAL=8.0
MAX_LOG_BYTES=$((5 * 1024 * 1024))  # 5MB

# ---------- 유틸 ----------
calc_md5() {
  if command -v md5sum >/dev/null 2>&1; then
    echo -n "$1" | md5sum | awk '{print $1}'
  else
    echo -n "$1" | md5 -q
  fi
}

stat_size() {
  if [ -f "$1" ]; then
    stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

ensure_local_dirs() {
  mkdir -p "$LOCAL_LOG_DIR"
}

rotate_log_if_needed() {
  local size
  size=$(stat_size "$LOG_FILE")
  if [ "$size" -gt "$MAX_LOG_BYTES" ]; then
    mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
  fi
}

log_message() {
  ensure_local_dirs
  rotate_log_if_needed
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] $1" >> "$LOG_FILE"
}

# ---------- bc 대안 (macOS 기본 설치되지 않음) ----------
compare_float() {
  local num1="$1"
  local operator="$2" 
  local num2="$3"
  
  # bc가 있으면 사용
  if command -v bc >/dev/null 2>&1; then
    echo "$num1 $operator $num2" | bc -l
  else
    # bc 없으면 awk 사용
    awk "BEGIN {print ($num1 $operator $num2) ? 1 : 0}"
  fi
}

# ---------- 이벤트 파일 초기화 ----------
ensure_event_file() {
  local today
  today=$(date +%Y%m%d)
  EVENT_FILE="$LOCAL_LOG_DIR/${EVENT_FILE_BASENAME}_${today}.json"
  if [ ! -f "$EVENT_FILE" ]; then
    echo "[]" > "$EVENT_FILE"
  fi
}

# ---------- 이벤트 생성 ----------
create_event() {
  local severity="$1"
  local type="$2"
  local message="$3"
  local value="$4"

  local event_id
  event_id="$(date +%s)_$(calc_md5 "$type$message" | cut -c1-8)"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  # 이벤트 JSON 생성 (jq 없이도 작동)
  local event_json
  event_json="{\"event_id\":\"$event_id\",\"timestamp\":\"$timestamp\",\"severity\":\"$severity\",\"type\":\"$type\",\"message\":\"$message\",\"value\":\"$value\",\"source\":\"$STORAGE_NAME\",\"hostname\":\"$(hostname)\"}"

  # 기존 이벤트 확인 및 중복 방지
  if grep -q "\"event_id\":\"$event_id\"" "$EVENT_FILE" 2>/dev/null; then
    log_message "중복 이벤트 무시: $event_id"
    return
  fi

  # JSON 배열에 안전하게 추가
  local tmp_file
  tmp_file=$(mktemp)
  
  if command -v jq >/dev/null 2>&1; then
    # jq가 있는 경우
    if jq --argjson new "$event_json" '. += [$new]' "$EVENT_FILE" > "$tmp_file" 2>/dev/null; then
      mv "$tmp_file" "$EVENT_FILE"
    else
      log_message "jq 처리 실패, 수동 처리로 전환"
      manual_json_append "$event_json"
    fi
  else
    # jq가 없는 경우 수동 처리
    manual_json_append "$event_json"
  fi
  
  rm -f "$tmp_file" 2>/dev/null

  log_message "$severity: $message (value: $value)"
}

# jq 없이 JSON 배열에 추가하는 함수
manual_json_append() {
  local new_event="$1"
  local tmp_file
  tmp_file=$(mktemp)
  
  # 파일 내용이 빈 배열인지 확인
  if [ "$(cat "$EVENT_FILE")" = "[]" ]; then
    echo "[$new_event]" > "$EVENT_FILE"
  else
    # 마지막 ] 제거하고 새 이벤트 추가
    sed '$ s/]$//' "$EVENT_FILE" > "$tmp_file"
    echo ",$new_event]" >> "$tmp_file"
    mv "$tmp_file" "$EVENT_FILE"
  fi
  
  rm -f "$tmp_file" 2>/dev/null
}

# ---------- 체크 함수 ----------
check_storage_exists() {
  log_message "테스트 스토리지 존재 여부 체크 시작"
  if [ -d "$SHARED_PATH" ]; then
    log_message "테스트 스토리지 확인됨: $SHARED_PATH"
  else
    create_event "WARNING" "STORAGE_MISSING" "테스트 스토리지 디렉토리가 존재하지 않음: $SHARED_PATH" "0"
  fi
}

check_disk_usage() {
  log_message "디스크 사용률 체크 시작"
  
  # macOS df 출력 파싱 개선
  df -h | tail -n +2 | while IFS= read -r line; do
    # 여러 공백을 하나로 정규화
    line=$(echo "$line" | tr -s ' ')
    
    # df 출력이 두 줄에 걸쳐 있는 경우 처리
    if ! echo "$line" | grep -q '%'; then
      continue
    fi
    
    filesystem=$(echo "$line" | awk '{print $1}')
    percent=$(echo "$line" | awk '{print $(NF-1)}' | sed 's/%//')
    mountpoint=$(echo "$line" | awk '{print $NF}')
    
    # 숫자가 아닌 경우 건너뛰기
    if ! [ "$percent" -eq "$percent" ] 2>/dev/null; then
      continue
    fi
    
    log_message "DEBUG: 파일시스템=$filesystem, 사용률=$percent%, 마운트=$mountpoint"
    
    if [ "$percent" -ge "$DISK_CRITICAL" ]; then
      create_event "CRITICAL" "DISK_USAGE" "디스크 사용률 위험: $mountpoint (${percent}%)" "$percent"
    elif [ "$percent" -ge "$DISK_WARNING" ]; then
      create_event "WARNING" "DISK_USAGE" "디스크 사용률 경고: $mountpoint (${percent}%)" "$percent"
    fi
  done
}

check_io_performance() {
  log_message "IO 성능 체크 시작"
  
  # macOS에서 iostat 사용법이 다름
  if ! command -v iostat >/dev/null 2>&1; then
    log_message "iostat 없음 — IO 체크 생략"
    return
  fi

  # macOS iostat: iostat -d 1 2 (1초 간격으로 2번)
  local iostat_output
  iostat_output=$(iostat -d 1 2 2>/dev/null | tail -n +3 | tail -1)
  
  if [ -n "$iostat_output" ]; then
    # macOS iostat 출력에서 KB/t, tps, MB/s 등을 확인
    local tps
    tps=$(echo "$iostat_output" | awk '{print $2}')
    
    # TPS(Transfers per second)가 높으면 IO 부하가 높다고 판단
    if [ -n "$tps" ] && awk "BEGIN {exit !($tps > 100)}" 2>/dev/null; then
      create_event "WARNING" "HIGH_IO" "높은 IO 활동: ${tps} TPS" "$tps"
    fi
    
    log_message "DEBUG: iostat TPS=$tps"
  else
    log_message "iostat 출력 없음 — IO 체크 생략"
  fi
}

check_memory_usage() {
  log_message "메모리 사용률 체크 시작"
  
  if ! command -v vm_stat >/dev/null 2>&1 || ! command -v sysctl >/dev/null 2>&1; then
    log_message "vm_stat/sysctl 없음 — 메모리 체크 생략"
    return
  fi
  
  # 페이지 크기와 총 메모리 가져오기
  local pagesize total_bytes
  pagesize=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
  total_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  
  if [ "$total_bytes" -eq 0 ]; then
    log_message "총 메모리 크기를 가져올 수 없음"
    return
  fi
  
  # vm_stat에서 페이지 정보 추출
  local vm_output free_pages inactive_pages speculative_pages
  vm_output=$(vm_stat 2>/dev/null)
  
  free_pages=$(echo "$vm_output" | awk '/Pages free/ {gsub(/\./,"",$3); print $3}' || echo 0)
  inactive_pages=$(echo "$vm_output" | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}' || echo 0)
  speculative_pages=$(echo "$vm_output" | awk '/Pages speculative/ {gsub(/\./,"",$3); print $3}' || echo 0)
  
  # 기본값 설정
  free_pages=${free_pages:-0}
  inactive_pages=${inactive_pages:-0}
  speculative_pages=${speculative_pages:-0}

  # 사용 가능한 메모리 계산
  local available_bytes used_bytes usage_percent
  available_bytes=$(( (free_pages + inactive_pages + speculative_pages) * pagesize ))
  used_bytes=$(( total_bytes - available_bytes ))
  usage_percent=$(( used_bytes * 100 / total_bytes ))

  log_message "DEBUG: 총메모리=$(( total_bytes / 1024 / 1024 ))MB, 사용률=${usage_percent}%"

  if [ "$usage_percent" -ge "$MEMORY_CRITICAL" ]; then
    create_event "CRITICAL" "MEMORY_USAGE" "메모리 사용률 위험: ${usage_percent}%" "$usage_percent"
  fi
}

check_system_load() {
  log_message "시스템 로드 체크 시작"
  
  # uptime에서 load average 추출 (macOS 형식)
  local load_avg
  load_avg=$(uptime | sed 's/.*load averages*: //' | awk '{print $1}' | sed 's/,//')
  
  if [ -n "$load_avg" ]; then
    log_message "DEBUG: 시스템 로드=$load_avg"
    
    # 부동소수점 비교
    if [ "$(compare_float "$load_avg" ">" "$LOAD_CRITICAL")" -eq 1 ]; then
      create_event "CRITICAL" "HIGH_LOAD" "시스템 로드 과부하: $load_avg" "$load_avg"
    fi
  else
    log_message "시스템 로드를 가져올 수 없음"
  fi
}

check_disk_growth() {
  log_message "디스크 증가율 체크 시작"
  
  local growth_file="$LOCAL_LOG_DIR/disk_growth.log"
  local current_usage_kb
  current_usage_kb=$(df -k / | tail -1 | awk '{print $3}')
  
  if [ -f "$growth_file" ]; then
    local previous_usage growth
    previous_usage=$(cat "$growth_file" 2>/dev/null || echo 0)
    growth=$((current_usage_kb - previous_usage))
    
    log_message "DEBUG: 디스크 증가량=${growth}KB"
    
    # 1GB 이상 증가시 경고 (1048576 KB)
    if [ "$growth" -gt 1048576 ]; then
      create_event "WARNING" "DISK_GROWTH" "디스크 사용량 급증: $((growth / 1024))MB/interval" "$growth"
    fi
  fi
  
  echo "$current_usage_kb" > "$growth_file"
}

check_log_files() {
  log_message "로그 파일 크기 체크 시작"
  
  # macOS 로그 경로들
  local log_paths="/var/log/system.log /var/log/install.log /var/log/kernel.log $LOG_FILE"
  
  for log_path in $log_paths; do
    if [ -f "$log_path" ]; then
      local size_mb
      size_mb=$(du -m "$log_path" 2>/dev/null | cut -f1)
      
      if [ -n "$size_mb" ] && [ "$size_mb" -gt 100 ]; then
        create_event "WARNING" "LARGE_LOG" "대용량 로그 파일: $log_path (${size_mb}MB)" "$size_mb"
      fi
    fi
  done
}

# 테스트 이벤트 생성 함수
create_test_events() {
  log_message "테스트 이벤트 생성"
  create_event "WARNING" "TEST_WARNING" "테스트 경고 메시지" "50"
  create_event "CRITICAL" "TEST_CRITICAL" "테스트 치명적 메시지" "95"
  create_event "INFO" "TEST_INFO" "테스트 정보 메시지" "10"
}

# ---------- 메인 ----------
main() {
  ensure_local_dirs
  ensure_event_file
  log_message "=== 스토리지 모니터링 시작 ==="

  # 테스트 모드
  if [ "${1:-}" = "test" ]; then
    log_message "테스트 모드 실행"
    create_test_events
    log_message "테스트 이벤트가 생성되었습니다: $EVENT_FILE"
    return
  fi

  # 필수 명령어 체크
  for cmd in df vm_stat sysctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_message "ERROR: 필수 명령어 없음: $cmd"
    fi
  done
  
  # 선택적 명령어 체크
  for cmd in iostat jq bc; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_message "WARNING: 선택적 명령어 없음: $cmd (기능 제한됨)"
    fi
  done

  # 모니터링 실행
  check_storage_exists
  check_disk_usage
  check_io_performance
  check_memory_usage
  check_system_load
  check_disk_growth
  check_log_files

  log_message "=== 스토리지 모니터링 완료 ==="
  log_message "생성된 이벤트 파일: $EVENT_FILE"
}

main "$@"