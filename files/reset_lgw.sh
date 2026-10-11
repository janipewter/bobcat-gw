#!/bin/sh
# Power up and reset the SX1302 LoRa concentrator of the Bobcat 300 G285.
#
#   reset_lgw.sh start   power-cycle the concentrator, then pulse its reset line
#   reset_lgw.sh stop    switch the concentrator off
#
# The concentrator's supply is switched by two GPIOs and its reset is a third. The pin
# numbers and the timing were worked out by the Bobcat300-TTN project
# (https://github.com/AdvdLaar/Bobcat300-TTN). They are sysfs (global) numbers and can be
# overridden in /etc/bobcat-gw/hw.env (POWER_GPIO, EXTRA_GPIO, RESET_GPIO).

[ -r /etc/bobcat-gw/hw.env ] && . /etc/bobcat-gw/hw.env
: "${POWER_GPIO:=125}" "${EXTRA_GPIO:=122}" "${RESET_GPIO:=149}"
SYSFS=/sys/class/gpio

# pin <number> low|high|input|free
pin() {
    if [ "$2" = free ]; then
        [ -e "$SYSFS/gpio$1" ] && echo "$1" > "$SYSFS/unexport"
        return 0
    fi
    if [ ! -e "$SYSFS/gpio$1" ]; then
        echo "$1" > "$SYSFS/export"
        sleep 0.1   # let udev set up the new gpio directory
    fi
    case "$2" in
        input) echo in > "$SYSFS/gpio$1/direction" ;;
        *)     echo "$2" > "$SYSFS/gpio$1/direction" ;;   # "low"/"high": output at that level
    esac
}

supply() {
    pin "$POWER_GPIO" "$1"
    pin "$EXTRA_GPIO" "$1"
}

case "$1" in
    start)
        supply low
        sleep 1
        supply high
        pin "$RESET_GPIO" free
        sleep 0.2
        pin "$RESET_GPIO" high
        sleep 0.1
        pin "$RESET_GPIO" low
        sleep 0.1
        pin "$RESET_GPIO" input
        ;;
    stop)
        pin "$RESET_GPIO" free
        supply low
        ;;
    *)
        echo "usage: $0 start|stop" >&2
        exit 1
        ;;
esac
exit 0
