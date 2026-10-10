#!/bin/sh
# SX1302 power/reset sequence for the Bobcat 300 G285.
# Based on reset_lgw.sh.bobcat from https://github.com/AdvdLaar/Bobcat300-TTN
#
# Usage: reset_lgw.sh start|stop
#
# GPIO numbers are sysfs (global) numbers and can be overridden from
# /etc/bobcat-gw/hw.env (RESET_GPIO, POWER_GPIO, EXTRA_GPIO).

[ -f /etc/bobcat-gw/hw.env ] && . /etc/bobcat-gw/hw.env

RESET_GPIO=${RESET_GPIO:-149}
POWER_GPIO=${POWER_GPIO:-125}
EXTRA_GPIO=${EXTRA_GPIO:-122}

WAIT_GPIO() {
    sleep 0.1
}

export_gpio() {
    [ -d /sys/class/gpio/gpio$1 ] || { echo "$1" > /sys/class/gpio/export; WAIT_GPIO; }
}

unexport_gpio() {
    [ -d /sys/class/gpio/gpio$1 ] && { echo "$1" > /sys/class/gpio/unexport; WAIT_GPIO; }
    return 0
}

set_out() {
    export_gpio $1
    echo "out" > /sys/class/gpio/gpio$1/direction
    echo "$2"  > /sys/class/gpio/gpio$1/value
}

pulse_reset() {
    export_gpio $RESET_GPIO
    echo "out" > /sys/class/gpio/gpio$RESET_GPIO/direction; WAIT_GPIO
    echo "1"   > /sys/class/gpio/gpio$RESET_GPIO/value; WAIT_GPIO
    echo "0"   > /sys/class/gpio/gpio$RESET_GPIO/value; WAIT_GPIO
    echo "in"  > /sys/class/gpio/gpio$RESET_GPIO/direction; WAIT_GPIO
}

case "$1" in
    start)
        set_out $POWER_GPIO 0
        set_out $EXTRA_GPIO 0
        sleep 1
        set_out $POWER_GPIO 1
        set_out $EXTRA_GPIO 1
        unexport_gpio $RESET_GPIO
        sleep 0.2
        pulse_reset
        ;;
    stop)
        unexport_gpio $RESET_GPIO
        set_out $POWER_GPIO 0
        set_out $EXTRA_GPIO 0
        ;;
    *)
        echo "Usage: $0 {start|stop}"
        exit 1
        ;;
esac

exit 0
