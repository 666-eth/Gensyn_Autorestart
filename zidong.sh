#!/bin/bash

# RL Swarm 自动重启脚本（无备份功能，使用Screen）

set -euo pipefail

# ========== 颜色定义 ==========
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ========== 日志函数 ==========
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug() { echo -e "${BLUE}[DEBUG]${NC} $1"; }

# ========== 配置 ==========
SCREEN_NAME="gensyn"
PID_FILE="/tmp/rl_swarm_daemon.pid"
LOG_FILE="/tmp/rl_swarm_screen.log"

# ========== 实例检测 ==========
check_existing_instance() {
    if [ -f "$PID_FILE" ]; then
        local existing_pid=$(cat "$PID_FILE")
        if kill -0 "$existing_pid" 2>/dev/null; then
            log_warn "已有实例运行 (PID: $existing_pid)"
            log_info "使用 --stop 停止旧实例"
            return 1
        else
            rm -f "$PID_FILE"
            log_info "清理过期的 PID 文件"
        fi
    fi
    return 0
}

create_pid_file() {
    echo $$ > "$PID_FILE"
    log_info "创建 PID 文件: $PID_FILE (PID: $$)"
}

cleanup_pid_file() {
    [ -f "$PID_FILE" ] && rm -f "$PID_FILE" && log_info "清理 PID 文件: $PID_FILE"
}

check_screen() {
    if ! command -v screen &> /dev/null; then
        log_error "未安装 screen，正在安装..."
        apt-get update && apt-get install -y screen
    fi
}

setup_screen() {
    log_info "设置 Screen 会话: $SCREEN_NAME"
    local count=$(screen -list | grep -c "$SCREEN_NAME" || echo 0)
    if [ "$count" -gt 1 ]; then
        log_warn "检测到多个 screen 会话，清理中..."
        screen -ls | grep "$SCREEN_NAME" | awk '{print $1}' | while read session; do
            screen -S "$session" -X quit 2>/dev/null || true
        done
        sleep 2
    fi
}

start_or_restart_rl_swarm() {
    local is_restart=${1:-false}
    if [ "$is_restart" = true ]; then
        log_info "重启 RL Swarm..."
        screen -ls | grep "$SCREEN_NAME" | awk '{print $1}' | while read session; do
            screen -S "$session" -X quit 2>/dev/null || true
        done
        while screen -list | grep -q "$SCREEN_NAME"; do sleep 1; done
    else
        log_info "启动 RL Swarm..."
    fi

    screen -dmS "$SCREEN_NAME" bash -c "cd /root && exec bash"
    sleep 2
    screen -S "$SCREEN_NAME" -X stuff "cd /root/rl-swarm$(printf '\r')"
    sleep 1
    screen -S "$SCREEN_NAME" -X stuff "source .venv/bin/activate$(printf '\r')"
    sleep 1
    screen -S "$SCREEN_NAME" -X stuff "./run_rl_swarm.sh$(printf '\r')"

    screen -S "$SCREEN_NAME" -X logfile "$LOG_FILE"
    screen -S "$SCREEN_NAME" -X log on

    monitor_rl_swarm
}

monitor_rl_swarm() {
    log_info "开始监控 RL Swarm..."
    while true; do
        [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -gt 10485760 ] && rm -f "$LOG_FILE"
        screen -S "$SCREEN_NAME" -X logfile "$LOG_FILE"
        screen -S "$SCREEN_NAME" -X log on
        sleep 5

        startup_complete=false
        auth_handled=false
        startup_start_time=$(date +%s)
        echo "$(date +%s)" > /tmp/last_log_update.tmp

        tail -f "$LOG_FILE" 2>/dev/null | while read line; do
            clean_line=$(echo "$line" | sed 's/\x1b\[[0-9;]*m//g' | sed 's/\r//g')
            [ -n "$clean_line" ] && echo "$clean_line"
            echo "$(date +%s)" > /tmp/last_log_update.tmp

            [[ "$clean_line" =~ (Good\ luck|Starting\ round:|Connected\ to\ peer) ]] && startup_complete=true

            if [ "$auth_handled" = false ] && echo "$clean_line" | grep -q "Would you like to push models"; then
                auth_handled=true
                sleep 2
                screen -S "$SCREEN_NAME" -X stuff "N$(printf '\r')"
                sleep 1
                screen -S "$SCREEN_NAME" -X stuff "Gensyn/Qwen2.5-0.5B-Instruct$(printf '\r')"
            fi

            if echo "$clean_line" | grep -E "Exception occurred|Traceback"; then
                log_warn "检测到异常，准备重启..."
                sleep 20
                start_or_restart_rl_swarm true
                break
            fi

            if echo "$clean_line" | grep -E "Terminated|Killed|Aborted|Segmentation fault"; then
                log_warn "程序崩溃，准备重启..."
                sleep 10
                start_or_restart_rl_swarm true
                break
            fi

            if echo "$clean_line" | grep -q "Starting round:"; then
                current_round=$(echo "$clean_line" | grep -o "Starting round: [0-9]*" | grep -o "[0-9]*")
                if [ -n "$current_round" ]; then
                    target_score=$(timeout 10 curl -s "https://dashboard.gensyn.ai/api/v1/peer?name=untamed%20alert%20rhino" | grep -o '"score":[0-9]*' | grep -o '[0-9]*')
                    if [ -n "$target_score" ]; then
                        diff=$((current_round - target_score))
                        if [ $diff -lt 4712 ]; then
                            log_warn "round 落后 $diff，准备重启..."
                            sleep 5
                            start_or_restart_rl_swarm true
                            break
                        fi
                    fi
                fi
            fi
        done

        sleep 5
    done
}

cleanup() {
    log_info "清理临时文件..."
    rm -f "$LOG_FILE" /tmp/rl_swarm_daemon.log /tmp/last_log_update.tmp
    cleanup_pid_file
}

show_help() {
    echo "用法:"
    echo "  $0                # 前台运行"
    echo "  $0 --daemon       # 后台运行"
    echo "  $0 --status       # 显示状态"
    echo "  $0 --stop         # 停止脚本"
}

show_status() {
    echo "=== RL Swarm 状态 ==="
    echo -n "进程状态: "
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "运行中 (PID: $pid)"
        else
            echo "PID 文件存在，但进程已停止"
        fi
    else
        echo "未运行"
    fi

    echo "Screen 会话:"
    screen -list | grep "$SCREEN_NAME" || echo "  无"
    echo "RL Swarm 进程:"
    ps aux | grep -E "run_rl_swarm|rgym_exp" | grep -v grep || echo "  无"
}

main() {
    case "${1:-}" in
        --help) show_help; exit 0 ;;
        --status) show_status; exit 0 ;;
        --stop)
            log_info "停止 RL Swarm..."
            if [ -f "$PID_FILE" ]; then
                pid=$(cat "$PID_FILE")
                kill "$pid" 2>/dev/null || true
                kill -9 "$pid" 2>/dev/null || true
            fi
            screen -ls | grep "$SCREEN_NAME" | awk '{print $1}' | while read session; do
                screen -S "$session" -X quit 2>/dev/null || true
            done
            cleanup
            exit 0
            ;;
        --daemon)
            log_info "后台运行..."
            nohup "$0" > /tmp/rl_swarm_daemon.log 2>&1 &
            echo "后台运行中，日志查看：tail -f /tmp/rl_swarm_daemon.log"
            exit 0
            ;;
    esac

    log_info "启动 RL Swarm 自动重启脚本..."
    if ! check_existing_instance; then exit 1; fi
    create_pid_file
    check_screen
    setup_screen
    trap 'cleanup; exit 0' SIGINT SIGTERM
    start_or_restart_rl_swarm
}

main "$@"
