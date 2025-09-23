#!/bin/bash
# =============================================================================
# macOS 스토리지 알림 클라이언트 (Bash 3.x 전용)
# 폐쇄망 환경용, 크론 기반
# =============================================================================

SHARED_PATH="$HOME/.storage_monitor"
PROCESSED_EVENTS_FILE="$SHARED_PATH/processed_events.txt"
LOG_FILE="$SHARED_PATH/storage_monitor.log"

# 로그 기록
log_message() {
    local level=${2:-INFO}
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $1" >> "$LOG_FILE"
}

# JSON 필드 추출 (개선된 버전)
parse_json_line() {
    local json="$1"
    local field="$2"
    # 따옴표 있는 경우와 없는 경우 모두 처리
    local result
    result=$(echo "$json" | sed -n 's/.*"'$field'": *"\([^"]*\)".*/\1/p')
    if [[ -z "$result" ]]; then
        result=$(echo "$json" | sed -n 's/.*"'$field'": *\([^,}]*\).*/\1/p' | sed 's/^ *//;s/ *$//')
    fi
    echo "$result"
}

# 알림 표시 함수
show_notification() {
    local title="$1"
    local message="$2"
    local severity="$3"
    
    log_message "알림 표시 시도: $title - $message"
    
    # 1. osascript로 대화상자 표시
    osascript -e "
    tell application \"System Events\"
        display dialog \"$message\" with title \"$title\" buttons {\"확인\"} default button 1 with icon note
    end tell
    " 2>/dev/null
    
    local dialog_result=$?
    log_message "대화상자 결과: $dialog_result"
    
    # 2. 시스템 알림도 함께 표시
    osascript -e "
    display notification \"$message\" with title \"$title\"
    " 2>/dev/null
    
    local notif_result=$?
    log_message "시스템 알림 결과: $notif_result"
    
    # 3. CRITICAL인 경우 음성 알림
    if [[ "$severity" == "CRITICAL" ]]; then
        say "중요한 스토리지 경고가 발생했습니다" &
        log_message "음성 알림 실행"
    fi
    
    return 0
}

# 이벤트 처리
process_new_events() {
    local events=("$@")
    local new_count=0
    
    log_message "처리할 이벤트 수: ${#events[@]}"

    for event in "${events[@]}"; do
        [[ -z "$event" ]] && continue
        
        log_message "이벤트 처리 중: $event"

        # event_id와 timestamp 추출
        local event_id timestamp
        event_id=$(parse_json_line "$event" "event_id")
        timestamp=$(parse_json_line "$event" "timestamp")
        
        log_message "추출된 ID: '$event_id', 시간: '$timestamp'"
        
        [[ -z "$event_id" || -z "$timestamp" ]] && {
            log_message "이벤트 ID 또는 타임스탬프가 없음"
            continue
        }

        local event_key="${event_id}|${timestamp}"

        # 이미 처리된 이벤트인지 확인
        if ! grep -Fxq "$event_key" "$PROCESSED_EVENTS_FILE" 2>/dev/null; then
            echo "$event_key" >> "$PROCESSED_EVENTS_FILE"
            ((new_count++))

            local severity message type source value
            severity=$(parse_json_line "$event" "severity")
            message=$(parse_json_line "$event" "message")
            type=$(parse_json_line "$event" "type")
            source=$(parse_json_line "$event" "source")
            value=$(parse_json_line "$event" "value")

            log_message "이벤트 정보 - 심각도: '$severity', 메시지: '$message', 소스: '$source'"

            local alert_title="스토리지 알림 - $source"
            local alert_message="$message"
            [[ -n "$type" ]] && alert_message="$alert_message"$'\n'"유형: $type"
            [[ -n "$value" ]] && alert_message="$alert_message"$'\n'"값: $value"

            # 알림 표시
            show_notification "$alert_title" "$alert_message" "$severity"
        else
            log_message "이미 처리된 이벤트: $event_key"
        fi
    done

    log_message "새 이벤트 $new_count개 처리 완료"
}

get_storage_events() {
    local file="$1"
    local events=()
    local buffer=""

    [[ ! -f "$file" ]] && {
        log_message "파일 없음: $file"
        return
    }

    log_message "이벤트 파일 읽기: $file"

    while IFS= read -r line; do
        # 배열 시작/끝은 무시
        [[ "$line" =~ ^\[$ || "$line" =~ ^\]$ ]] && continue

        # 버퍼에 이어붙이기 (앞뒤 공백 제거)
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        buffer="$buffer$line"

        # 객체 닫힘(}) 나오면 하나의 이벤트 완성
        if [[ "$line" == "}," || "$line" == "}" ]]; then
            # 마지막 , 제거
            buffer=$(echo "$buffer" | sed 's/},$/}/')
            events+=("$buffer")
            buffer=""
        fi
    done < "$file"

    log_message "읽어온 이벤트 수: ${#events[@]}"
    for e in "${events[@]}"; do
        echo "$e"
    done
}



# 테스트 이벤트 생성 함수 (디버깅용)
create_test_event() {
    local today_file="$SHARED_PATH/events_$(date '+%Y%m%d').json"
    local test_event="{\"event_id\":\"test_$(date +%s)\",\"timestamp\":\"$(date '+%Y-%m-%d %H:%M:%S')\",\"severity\":\"WARNING\",\"message\":\"테스트 스토리지 경고\",\"type\":\"disk_usage\",\"source\":\"system\",\"value\":\"85%\"}"
    
    echo "$test_event" >> "$today_file"
    log_message "테스트 이벤트 생성: $test_event"
}

# 메인
main() {
    log_message "스토리지 모니터 시작"
    
    mkdir -p "$SHARED_PATH"
    touch "$PROCESSED_EVENTS_FILE"
    touch "$LOG_FILE"

    # 인자로 "test"가 주어지면 테스트 이벤트 생성
    if [[ "$1" == "test" ]]; then
        log_message "테스트 모드 실행"
        create_test_event
    fi

    local today_file="$SHARED_PATH/events_$(date '+%Y%m%d').json"

    if [[ ! -f "$today_file" ]]; then
        log_message "오늘 이벤트 파일 없음: $today_file"
        exit 0
    fi

    # 이벤트 읽기를 배열로 처리
    local events_output events
    events_output=$(get_storage_events "$today_file")

    if [[ -z "$events_output" ]]; then
        log_message "읽어온 이벤트 없음"
        exit 0
    fi
    
    # 줄바꿈으로 분리하여 배열에 저장
    IFS=$'\n' read -r -a events <<< "$events_output"

    if [[ ${#events[@]} -eq 0 ]]; then
        log_message "처리할 이벤트 없음"
        exit 0
    fi

    process_new_events "${events[@]}"
    log_message "스토리지 모니터 완료"
}

main "$@"