from zxtouch.client import zxtouch


def main():
    device = zxtouch("127.0.0.1")

    # Replace with a bundle identifier installed on your device.
    target_bundle = "com.apple.springboard"

    print("Frontmost app:", device.front_most_app_id())
    print("Frontmost orientation:", device.front_most_orientation())

    print("App state:", device.app_state(target_bundle))
    print("App info:", device.app_info(target_bundle))

    # Example kill (avoid killing SpringBoard in practice).
    # device.app_kill(target_bundle)

    device.disconnect()


if __name__ == "__main__":
    main()
