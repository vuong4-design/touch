from zxtouch.client import zxtouch
from zxtouch.hardwarekeytypes import (
    HARDWARE_KEY_HOME,
    HARDWARE_KEY_VOLUME_UP,
    HARDWARE_KEY_VOLUME_DOWN,
    HARDWARE_KEY_LOCK,
)
import time


def press_key(device, key_type, delay=0.2):
    device.key_down(key_type)
    time.sleep(delay)
    device.key_up(key_type)


def main():
    device = zxtouch("127.0.0.1")

    press_key(device, HARDWARE_KEY_VOLUME_UP)
    press_key(device, HARDWARE_KEY_VOLUME_DOWN)
    press_key(device, HARDWARE_KEY_HOME)
    press_key(device, HARDWARE_KEY_LOCK)

    device.disconnect()


if __name__ == "__main__":
    main()
