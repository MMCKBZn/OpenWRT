#!/usr/bin/env bash
# 添加 LED 按钮控制（复位键切换 LED 颜色，长按 10 秒重启）
set -Eeuo pipefail

echo ">>> 集成 LED 按钮控制"

# 获取复位键 GPIO 号（从设备树解析）
# gpiochip0 起始 512，复位键使用 gpio 偏移 9
DTS_DIR="$(find target/linux/qualcommax/files -name "*.dts" -path "*/ipq6018*" 2>/dev/null | head -1)"
if [ -n "$DTS_DIR" ]; then
    echo ">>> 从 DTS 解析按键 GPIO: $DTS_DIR"
fi

# 创建 LED 控制守护程序
mkdir -p files/usr/bin
cat > files/usr/bin/led-button << 'DAEMON_EOF'
#!/bin/sh

# ============================================
# LED 按钮控制守护程序
# 京东云无线宝 百里 RE-SS-01
# - 按 1 下：蓝灯
# - 按 2 下：红灯
# - 按 3 下：绿灯
# - 按 4 下：关灯
# - 长按 10 秒：重启
# ============================================

# LED 路径
LED_RED="/sys/class/leds/red:status/brightness"
LED_GREEN="/sys/class/leds/green:status/brightness"
LED_BLUE="/sys/class/leds/blue:status/brightness"

# 复位键 GPIO（gpiochip0 偏移 9 = 绝对编号 521）
BUTTON_GPIO=521
BUTTON_GPIO_PATH="/sys/class/gpio/gpio${BUTTON_GPIO}"

# 配置
CLICK_TIMEOUT=2          # 连续点击等待时间（秒）
LONG_PRESS_THRESHOLD=10  # 长按触发时间（秒）
POLL_INTERVAL=0.05       # 轮询间隔（秒）

# 状态变量
click_count=0
last_event_time=0
press_start_time=0
button_pressed=0

# 初始化 LED
init_led() {
    for led in "$LED_RED" "$LED_GREEN" "$LED_BLUE"; do
        [ -w "$led" ] && echo 0 > "$led" 2>/dev/null
    done
}

# 设置 LED 颜色
# 参数: 1=蓝色 2=红色 3=绿色 0=关闭
set_led() {
    case "$1" in
        1)  # 蓝色
            echo 255 > "$LED_BLUE" 2>/dev/null
            echo 0 > "$LED_RED" 2>/dev/null
            echo 0 > "$LED_GREEN" 2>/dev/null
            ;;
        2)  # 红色
            echo 0 > "$LED_BLUE" 2>/dev/null
            echo 255 > "$LED_RED" 2>/dev/null
            echo 0 > "$LED_GREEN" 2>/dev/null
            ;;
        3)  # 绿色
            echo 0 > "$LED_BLUE" 2>/dev/null
            echo 0 > "$LED_RED" 2>/dev/null
            echo 255 > "$LED_GREEN" 2>/dev/null
            ;;
        0|*) # 关闭
            echo 0 > "$LED_BLUE" 2>/dev/null
            echo 0 > "$LED_RED" 2>/dev/null
            echo 0 > "$LED_GREEN" 2>/dev/null
            ;;
    esac
}

# 闪烁提示（点击反馈）
blink_feedback() {
    local count="$1"
    local i=0
    # 快速闪烁蓝色
    while [ "$i" -lt "$count" ]; do
        echo 255 > "$LED_BLUE" 2>/dev/null
        sleep 0.1
        echo 0 > "$LED_BLUE" 2>/dev/null
        sleep 0.1
        i=$((i + 1))
    done
}

# 执行点击操作
execute_action() {
    local count="$1"
    case "$count" in
        1) set_led 1 ;;  # 蓝色
        2) set_led 2 ;;  # 红色
        3) set_led 3 ;;  # 绿色
        4) set_led 0 ;;  # 关闭
        *) ;;
    esac
}

# 初始化 GPIO
init_gpio() {
    if [ ! -d "$BUTTON_GPIO_PATH" ]; then
        echo "$BUTTON_GPIO" > /sys/class/gpio/export 2>/dev/null || true
        # 等待 sysfs 创建
        local retry=0
        while [ ! -d "$BUTTON_GPIO_PATH" ] && [ "$retry" -lt 10 ]; do
            sleep 0.1
            retry=$((retry + 1))
        done
    fi
    # 设置方向为输入
    if [ -d "$BUTTON_GPIO_PATH" ]; then
        echo "in" > "${BUTTON_GPIO_PATH}/direction" 2>/dev/null || true
        return 0
    fi
    return 1
}

# 读取 GPIO 值（取反：active low）
read_gpio() {
    local val
    val=$(cat "${BUTTON_GPIO_PATH}/value" 2>/dev/null)
    # 取反（active low，按下=0，松开=1）
    if [ "$val" = "0" ]; then
        echo 1
    else
        echo 0
    fi
}

# 获取当前时间戳（秒）
get_timestamp() {
    awk '{print $1}' /proc/uptime
}

# 主循环
main_loop() {
    init_led

    if ! init_gpio; then
        logger -t led-button "无法初始化 GPIO $BUTTON_GPIO"
        exit 1
    fi

    local prev_state=0
    local current_state
    local now
    local elapsed
    local hold_time

    logger -t led-button "LED 按钮控制守护程序已启动"

    while true; do
        current_state=$(read_gpio)
        now=$(get_timestamp)

        # 检测下降沿（按下：1->0 逻辑取反后是 0->1 的边沿）
        # 因为我们取反了，所以按下是 1
        if [ "$current_state" = "1" ] && [ "$prev_state" = "0" ]; then
            # 按下事件
            press_start_time="$now"
            button_pressed=1
        fi

        # 检测上升沿（松开：0->1）
        if [ "$current_state" = "0" ] && [ "$prev_state" = "1" ]; then
            # 松开事件
            hold_time=$(echo "$now - $press_start_time" | awk '{print int($1)}')
            button_pressed=0

            if [ "$hold_time" -ge "$LONG_PRESS_THRESHOLD" ]; then
                # 长按 10 秒以上 -> 重启
                logger -t led-button "长按 ${hold_time} 秒，执行重启"
                set_led 2  # 红灯表示重启
                sleep 1
                sync
                reboot
                exit 0
            elif [ "$hold_time" -lt 1 ]; then
                # 短按（<1秒）-> 计为一次点击
                click_count=$((click_count + 1))
                blink_feedback "$click_count"
                last_event_time="$now"

                # 如果已到 4 次，立即执行
                if [ "$click_count" -ge 4 ]; then
                    execute_action "$click_count"
                    click_count=0
                fi
            fi
        fi

        # 检查点击超时（如果有点击但超时未继续按，执行动作）
        if [ "$click_count" -gt 0 ] && [ "$button_pressed" = "0" ]; then
            elapsed=$(echo "$now - $last_event_time" | awk '{print int($1)}')
            if [ "$elapsed" -ge "$CLICK_TIMEOUT" ]; then
                execute_action "$click_count"
                click_count=0
            fi
        fi

        prev_state="$current_state"
        sleep "$POLL_INTERVAL"
    done
}

main_loop "$@"
DAEMON_EOF
chmod +x files/usr/bin/led-button

# 创建 init.d 服务
mkdir -p files/etc/init.d
cat > files/etc/init.d/led-button << 'INIT_EOF'
#!/bin/sh /etc/rc.common
# LED 按钮控制服务

USE_PROCD=1
START=99
STOP=10

start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/led-button
    procd_set_param respawn 5 30 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    # 关闭 LED
    echo 0 > /sys/class/leds/red:status/brightness 2>/dev/null
    echo 0 > /sys/class/leds/green:status/brightness 2>/dev/null
    echo 0 > /sys/class/leds/blue:status/brightness 2>/dev/null
}

service_triggers() {
    procd_add_reload_trigger "led-button"
}
INIT_EOF
chmod +x files/etc/init.d/led-button

# 禁用原复位键功能（避免冲突）
# 原 /etc/rc.button/reset 短按重启、长按恢复出厂，与我们的功能冲突
# 通过覆盖为空脚本来禁用
mkdir -p files/etc/rc.button
cat > files/etc/rc.button/reset << 'BUTTON_EOF'
#!/bin/sh
# 复位键由 led-button 守护程序接管
# 此文件为空，仅用于禁用默认行为
return 0
BUTTON_EOF
chmod +x files/etc/rc.button/reset

echo ">>> LED 按钮控制集成完毕"