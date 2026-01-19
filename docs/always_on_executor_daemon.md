# Always-on Executor Daemon + Optional Desktop Orchestrator

Tài liệu này là task list kèm prompt để nhóm triển khai kiến trúc "Always-on Executor Daemon + Optional Desktop Orchestrator" cho ZXTouch (iOS 13-14 rootful), ưu tiên thay đổi ít phá API Python hiện tại.

## Mục tiêu chung

- Daemon on-device luôn chạy: JobManager + ResourceLock + Watchdog + logging + state persistence.
- Plan-based execution: desktop compile script thành Plan(JSON) với steps + guards + retry + on_fail + budgets.
- Attach/Detach: lease + heartbeat, mất mạng thì daemon tự chạy; có thể reattach.
- Idempotent protocol: plan_id/step_id/seq chống duplicate trên WAN.
- Telemetry API: progress, logs, screenshot crop/downscale.

---

## Phase 0 — Khảo sát & chuẩn bị

### Task 0.1 — Rà soát socket protocol hiện tại
**Mục tiêu:** Xác định format request/response và các command đang có trong Python client.

**Prompt gợi ý**
```
Đọc module Python zxtouch hiện tại để xác định: (1) cấu trúc message gửi qua socket 6000, (2) các lệnh đang hỗ trợ, (3) pattern xử lý lỗi/response. Tóm tắt thành bảng: command -> payload -> response.
```

### Task 0.2 — Mapping API cũ → step primitives
**Mục tiêu:** Liệt kê lệnh hiện có (touch, screenshot, image matching, run script, …) và map thành step primitives.

**Prompt gợi ý**
```
Từ kết quả Task 0.1, lập danh sách step primitives tối thiểu cần hỗ trợ cho Plan execution. Chỉ ra primitive nào có thể reuse ngay, primitive nào cần thêm code mới.
```

---

## Appendix A — Tóm tắt socket protocol hiện tại (Python client)

### A.1 Định dạng message

- **Request**: `"{task_type};;{arg1};;{arg2};;...\\r\\n"` (task_type là số, args được nối bằng `;;`).【F:layout/usr/lib/python3.7/site-packages/zxtouch/datahandler.py†L1-L9】
- **Response**: chuỗi bắt đầu bằng ký tự `"0"` là thành công; nếu không phải `"0"` thì lỗi. Trường lỗi lấy ở phần tử thứ 2 nếu có. Dữ liệu trả về là danh sách các field sau khi split `;;`.【F:layout/usr/lib/python3.7/site-packages/zxtouch/datahandler.py†L11-L24】
- Hầu hết lệnh nhận về `Result tuple`: `(success, error_message_or_value)` sau khi `decode_socket_data` parse.【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L40-L101】

### A.2 Bảng command → payload → response

| Command (method) | task_type | Payload (format_socket_data args) | Response (decode_socket_data) |
| --- | --- | --- | --- |
| `touch` | `TASK_PERFORM_TOUCH=10` | single string: `"1{type}{finger:02d}{x*10:05d}{y*10:05d}"` | No return parsing (fire-and-forget).【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L14-L34】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L1-L2】 |
| `touch_with_list` | `TASK_PERFORM_TOUCH=10` | `"len" + event_data`, mỗi event: `"{type}{finger:02d}{x*10:05d}{y*10:05d}"` | No return parsing (fire-and-forget).【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L35-L51】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L1-L2】 |
| `switch_to_app` | `TASK_PROCESS_BRING_FOREGROUND=11` | `bundle_identifier` | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L53-L65】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L1-L3】 |
| `show_alert_box` | `TASK_SHOW_ALERT_BOX=12` | `title`, `content`, `duration` | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L67-L81】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L2-L4】 |
| `run_shell_command` | `TASK_RUN_SHELL=13` | `command` | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L83-L91】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L2-L5】 |
| `start_touch_recording` | `TASK_TOUCH_RECORDING_START=14` | (no args) | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L93-L101】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L3-L6】 |
| `stop_touch_recording` | `TASK_TOUCH_RECORDING_STOP=15` | (no args) | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L103-L111】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L3-L6】 |
| `accurate_usleep` | `TASK_USLEEP=18` | `microseconds` | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L113-L122】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L5-L9】 |
| `play_script` | `TASK_PLAY_SCRIPT=19` | `script_absolute_path` | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L124-L132】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L5-L9】 |
| `force_stop_script_play` | `TASK_PLAY_SCRIPT_FORCE_STOP=20` | (no args) | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L134-L137】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L7-L10】 |
| `image_match` | `TASK_TEMPLATE_MATCH=21` | `template_path`, `max_try_times`, `acceptable_value`, `scaleRation` | `(success, {x,y,width,height})` from 4 fields |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L139-L158】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L7-L11】 |
| `screenshot` | `TASK_SCREENSHOT=29` | `1`, `filePath`, `[x,y,w,h]` optional | `(success, output_path)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L160-L184】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L17-L20】 |
| `save_to_system_album` | `TASK_SCREENSHOT=29` | `2`, `filePath` | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L300-L307】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L17-L20】 |
| `clear_system_album` | `TASK_SCREENSHOT=29` | `3` | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L309-L312】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L17-L20】 |
| `key_down` | `TASK_HARDWARE_KEY=30` | `action_down`, `key_type` | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L186-L200】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L18-L20】 |
| `key_up` | `TASK_HARDWARE_KEY=30` | `action_up`, `key_type` | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L202-L214】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L18-L20】 |
| `app_kill` | `TASK_APP_KILL=31` | `bundle_identifier` | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L216-L220】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L18-L21】 |
| `app_state` | `TASK_APP_STATE=32` | `bundle_identifier` | `(success, state)` from first field |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L222-L231】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L19-L22】 |
| `app_info` | `TASK_APP_INFO=33` | `bundle_identifier` | `(success, info_dict)` from `bundle_id;;name;;short_version;;bundle_version;;state` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L233-L261】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L19-L23】 |
| `front_most_app_id` | `TASK_FRONTMOST_APP_ID=34` | (no args) | `(success, bundle_id)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L263-L270】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L20-L24】 |
| `front_most_orientation` | `TASK_FRONTMOST_APP_ORIENTATION=35` | (no args) | `(success, orientation)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L272-L279】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L20-L24】 |
| `set_auto_launch` | `TASK_SET_AUTO_LAUNCH=36` | `name`, `script`, `enabled(0/1)` | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L281-L291】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L20-L25】 |
| `list_auto_launch` | `TASK_LIST_AUTO_LAUNCH=37` | (no args) | `(success, entries[])` parsed from `"name,,script,,enabled;;..."` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L293-L314】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L21-L25】 |
| `set_timer` | `TASK_SET_TIMER=38` | `name`, `interval`, `repeat(0/1)`, `script` | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L316-L326】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L21-L26】 |
| `remove_timer` | `TASK_REMOVE_TIMER=39` | `name` | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L328-L332】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L22-L26】 |
| `keep_awake` | `TASK_KEEP_AWAKE=40` | `enabled(0/1)` | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L334-L338】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L22-L27】 |
| `stop` | `TASK_STOP_SCRIPT=41` | (no args) | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L340-L344】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L23-L27】 |
| `dialog` | `TASK_DIALOG=42` | `title`, `message`, `ok`, `cancel` | `(success, response_index)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L346-L363】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L23-L28】 |
| `clear_dialog_values` | `TASK_CLEAR_DIALOG=43` | (no args) | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L365-L369】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L24-L28】 |
| `root_dir` | `TASK_ROOT_DIR=44` | (no args) | `(success, path)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L371-L378】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L24-L29】 |
| `current_dir` | `TASK_CURRENT_DIR=45` | (no args) | `(success, path)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L380-L387】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L24-L29】 |
| `bot_path` | `TASK_BOT_PATH=46` | (no args) | `(success, path)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L389-L396】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L25-L29】 |
| `show_toast` | `TASK_SHOW_TOAST=22` | `toast_type`, `content`, `duration`, `position`, `fontSize` | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L360-L371】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L8-L12】 |
| `pick_color` | `TASK_COLOR_PICKER=23` | `x`, `y` | `(success, {red,green,blue})` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L332-L350】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L8-L13】 |
| `search_color` | `TASK_COLOR_SEARCHER=28` | `1`, `x`, `y`, `w`, `h`, `red_min`, `red_max`, `green_min`, `green_max`, `blue_min`, `blue_max`, `pixel_to_skip` | `(success, {x,y,red,green,blue})` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L352-L378】【F:layout/usr/lib/python3.7/site-packages/zxtouch/colorsearchtasktypes.py†L1-L1】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L16-L19】 |
| `show_keyboard` | `TASK_KEYBOARDIMPL=24` | `KEYBOARD_VIRTUAL_KEYBOARD`, `2` | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L381-L390】【F:layout/usr/lib/python3.7/site-packages/zxtouch/kbdtasktypes.py†L1-L7】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L9-L13】 |
| `hide_keyboard` | `TASK_KEYBOARDIMPL=24` | `KEYBOARD_VIRTUAL_KEYBOARD`, `1` | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L392-L401】【F:layout/usr/lib/python3.7/site-packages/zxtouch/kbdtasktypes.py†L1-L7】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L9-L13】 |
| `paste_from_clipboard` | `TASK_KEYBOARDIMPL=24` | `KEYBOARD_PASTE_FROM_CLIPBOARD` | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L403-L411】【F:layout/usr/lib/python3.7/site-packages/zxtouch/kbdtasktypes.py†L1-L7】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L9-L13】 |
| `get_text_from_clipboard` | `TASK_KEYBOARDIMPL=24` | `KEYBOARD_GET_TEXT_FROM_CLIPBOARD` | `(success, text)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L413-L424】【F:layout/usr/lib/python3.7/site-packages/zxtouch/kbdtasktypes.py†L1-L7】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L9-L13】 |
| `set_clipboard_text` | `TASK_KEYBOARDIMPL=24` | `KEYBOARD_SAVE_TEXT_TO_CLIPBOARD`, `text` | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L426-L435】【F:layout/usr/lib/python3.7/site-packages/zxtouch/kbdtasktypes.py†L1-L7】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L9-L13】 |
| `insert_text` | `TASK_KEYBOARDIMPL=24` | per-char: `KEYBOARD_INSERT_TEXT` or `KEYBOARD_DELETE_CHARACTERS` | Per-char decode; returns `(True, "")` overall |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L437-L462】【F:layout/usr/lib/python3.7/site-packages/zxtouch/kbdtasktypes.py†L1-L7】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L9-L13】 |
| `move_cursor` | `TASK_KEYBOARDIMPL=24` | `KEYBOARD_MOVE_CURSOR`, `offset` | `(success, error)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L465-L473】【F:layout/usr/lib/python3.7/site-packages/zxtouch/kbdtasktypes.py†L1-L7】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L9-L13】 |
| `get_screen_size` | `TASK_GET_DEVICE_INFO=25` | `DEVICE_INFO_TASK_GET_SCREEN_SIZE` | `(success, {width,height})` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L475-L486】【F:layout/usr/lib/python3.7/site-packages/zxtouch/deviceinfotasktypes.py†L1-L5】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L10-L14】 |
| `get_screen_orientation` | `TASK_GET_DEVICE_INFO=25` | `DEVICE_INFO_TASK_GET_SCREEN_ORIENTATION` | `(success, orientation)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L488-L498】【F:layout/usr/lib/python3.7/site-packages/zxtouch/deviceinfotasktypes.py†L1-L5】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L10-L14】 |
| `get_screen_scale` | `TASK_GET_DEVICE_INFO=25` | `DEVICE_INFO_TASK_GET_SCREEN_SCALE` | `(success, scale)` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L501-L511】【F:layout/usr/lib/python3.7/site-packages/zxtouch/deviceinfotasktypes.py†L1-L6】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L10-L14】 |
| `get_device_info` | `TASK_GET_DEVICE_INFO=25` | `DEVICE_INFO_TASK_GET_DEVICE_INFO` | `(success, {name, system_name, system_version, model, identifier_for_vendor})` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L513-L523】【F:layout/usr/lib/python3.7/site-packages/zxtouch/deviceinfotasktypes.py†L7-L8】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L10-L14】 |
| `get_battery_info` | `TASK_GET_DEVICE_INFO=25` | `DEVICE_INFO_TASK_GET_BATTERY_INFO` | `(success, {battery_state, battery_level, battery_state_string})` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L525-L537】【F:layout/usr/lib/python3.7/site-packages/zxtouch/deviceinfotasktypes.py†L7-L9】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L10-L14】 |
| `ocr` | `TASK_TEXT_RECOGNIZER=27` | `1`, `rect_data`, `custom_words`, `minimum_height`, `recognition_level`, `languages`, `auto_correct`, `debug_image_path` | `(success, list[{text,x,y,width,height}])` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L539-L583】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L13-L17】 |
| `get_supported_ocr_languages` | `TASK_TEXT_RECOGNIZER=27` | `2`, `recognition_level` | `(success, languages[])` |【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L585-L603】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L13-L17】 |

### A.3 Step primitives tối thiểu cho Plan execution

**Reuse ngay (dựa trên API hiện tại):**

- `touch` / `touch_list`: dựa trên `touch` và `touch_with_list` (TASK_PERFORM_TOUCH).【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L14-L51】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L1-L2】
- `sleep/usleep`: dùng `accurate_usleep` (TASK_USLEEP) để làm step delay chính xác.【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L113-L122】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L5-L9】
- `app_foreground`: dùng `switch_to_app` (TASK_PROCESS_BRING_FOREGROUND).【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L53-L65】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L1-L3】
- `app_state`/`frontmost_app`: dùng `app_state`, `front_most_app_id`, `front_most_orientation` để guard/check context.【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L222-L279】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L19-L24】
- `screenshot`: dùng `screenshot` (TASK_SCREENSHOT) để chụp ảnh phục vụ guard/telemetry (file-based).【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L160-L184】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L17-L20】
- `image_match`: dùng `image_match` (TASK_TEMPLATE_MATCH).【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L139-L158】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L7-L11】
- `ocr`: dùng `ocr` (TASK_TEXT_RECOGNIZER) cho guard text/vision cơ bản trên device.【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L539-L583】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L13-L17】
- `toast/alert/dialog`: dùng `show_toast`, `show_alert_box`, `dialog` để hiển thị trạng thái/confirm UI nếu cần.【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L67-L81】【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L301-L318】【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L360-L371】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L2-L4】
- `run_script`: dùng `play_script` / `stop` / `force_stop_script_play` để chạy legacy script (TASK_PLAY_SCRIPT/STOP).【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L124-L137】【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L296-L299】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L5-L9】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L23-L27】
- `keyboard` primitives: `insert_text`, `move_cursor`, `show_keyboard`, `hide_keyboard`, `paste_from_clipboard` (TASK_KEYBOARDIMPL).【F:layout/usr/lib/python3.7/site-packages/zxtouch/client.py†L381-L473】【F:layout/usr/lib/python3.7/site-packages/zxtouch/kbdtasktypes.py†L1-L7】【F:layout/usr/lib/python3.7/site-packages/zxtouch/tasktypes.py†L9-L13】

**Cần thêm code mới (không có API trực tiếp):**

- `plan_submit` / `plan_start` / `plan_pause` / `plan_resume` / `plan_cancel`: message types mới cho Plan lifecycle.
- `resource_lock` / `lease_heartbeat` / `attach` / `detach` / `reattach`: protocol mới để quản lý quyền điều khiển.
- `telemetry_progress` / `telemetry_logs` / `telemetry_screenshot_bytes`: API mới để stream log/progress và trả về ảnh qua socket (hiện screenshot chỉ lưu file trên device).
- `idempotent_step_exec`: cơ chế plan_id/step_id/seq và cache ACK để chống duplicate.

### A.4 JSON schema đề xuất cho Plan/Step/Guard

**Status triển khai:** ✅ Đã có dataclass `Plan/Step/Guard` + `from_dict/to_dict` trong `layout/usr/lib/python3.7/site-packages/zxtouch/plan.py`.

**Plan schema (v1, dạng JSON):**

```json
{
  "plan_id": "uuid",
  "plan_version": 1,
  "created_at": "2025-01-01T12:00:00Z",
  "budgets": {
    "time_ms": 300000,
    "touch_ops": 2000,
    "retry_total": 20
  },
  "steps": [
    {
      "step_id": "s1",
      "type": "touch",
      "payload": { "type": "DOWN", "finger": 1, "x": 300, "y": 500 },
      "guards": [],
      "retry": { "max": 0, "backoff_ms": 0 },
      "on_fail": { "action": "abort" },
      "budget": { "time_ms": 2000 }
    }
  ],
  "on_fail": { "action": "abort" }
}
```

### A.5 Đề xuất state persistence (JSON/SQLite)

**Gợi ý lưu state**: dùng SQLite (ổn định, query được) hoặc JSON (đơn giản, dễ debug). Cả hai nên lưu tối thiểu các trường sau:

- `plan_id`: định danh plan đang chạy.
- `current_step_id`: step hiện tại (cursor).
- `step_status`: trạng thái từng step (pending/running/done/failed).
- `last_seq`: map `{plan_id: {step_id: last_seq}}` cho idempotent ACK.
- `retry_counters`: map `{step_id: retry_count}`.
- `lease_info`: `{lease_id, lease_owner, lease_expiry_ts, heartbeat_interval_ms}`.
- `budgets_used`: `{plan_time_ms_used, touch_ops_used}`.
- `timestamps`: `{started_at, updated_at, last_checkpoint_at}`.

**Pseudo-code load/recover:**

```
function load_state():
    if state_store.exists():
        state = state_store.read()
        if state.plan_id and state.current_step_id:
            restore_plan(state.plan_id)
            restore_cursor(state.current_step_id)
            restore_retry(state.retry_counters)
            restore_idempotency(state.last_seq)
            restore_lease(state.lease_info)
            restore_budgets(state.budgets_used)
            return state
    return empty_state()

function checkpoint(state):
    state.updated_at = now()
    state_store.write(state)

function recover_on_startup():
    state = load_state()
    if state.plan_id is None:
        return idle
    if lease_expired(state.lease_info):
        enter_autonomous_mode()
    resume_from(state.current_step_id)
```

### A.6 Watchdog + budget enforcement

**Mục tiêu:** bảo vệ step/plan khỏi treo hoặc chạy quá hạn mức (time/touch ops). Watchdog hoạt động theo hai lớp:

1. **Step watchdog**: timeout per-step (`budget.time_ms`).
2. **Plan watchdog**: timeout toàn plan (`budgets.time_ms`) + giới hạn `touch_ops`/`retry_total`.

**Hành vi khi timeout:**

- Nếu step có `retry.max > 0` và chưa vượt retry: **retry** với `backoff_ms`.
- Nếu step có `on_fail.action`:
  - `goto`: nhảy sang `target`.
  - `skip`: đánh dấu step failed và tiếp tục.
  - `abort`: dừng plan và trả lỗi.
- Nếu không có `on_fail`: **abort** plan.

**Pseudo-code watchdog loop:**

```
function run_step(step):
    start = now()
    while true:
        result = execute(step)
        if result.success:
            return success
        if timed_out(start, step.budget.time_ms):
            return handle_fail(step, "step_timeout")
        if step.retry.count < step.retry.max:
            sleep(step.retry.backoff_ms)
            step.retry.count += 1
            continue
        return handle_fail(step, "step_error")

function check_plan_budget(plan):
    if elapsed(plan.started_at) > plan.budgets.time_ms:
        return handle_fail(plan, "plan_timeout")
    if plan.touch_ops_used > plan.budgets.touch_ops:
        return handle_fail(plan, "touch_budget_exceeded")
    if plan.retry_total_used > plan.budgets.retry_total:
        return handle_fail(plan, "retry_budget_exceeded")
```

**Format log/telemetry (gợi ý):**

- `event_type`: `step_start | step_success | step_retry | step_fail | plan_abort | plan_complete`.
- `plan_id`, `step_id`, `seq`, `timestamp`.
- `reason`: `step_timeout | plan_timeout | step_error | guard_fail | budget_exceeded`.
- `metrics`: `{duration_ms, retries, touch_ops_used}`.

### A.7 Attach/Heartbeat/Detach/Reattach message types & state machine

**Message types (đề xuất):**

- `ATTACH_REQ`: client → daemon. Payload: `{client_id, lease_ttl_ms, capabilities}`.
- `ATTACH_ACK`: daemon → client. Payload: `{lease_id, lease_expiry_ts, heartbeat_interval_ms, plan_state?}`.
- `HEARTBEAT`: client → daemon. Payload: `{lease_id, seq}`.
- `HEARTBEAT_ACK`: daemon → client. Payload: `{lease_id, server_ts, plan_state?}`.
- `DETACH`: client → daemon. Payload: `{lease_id, reason}`.
- `REATTACH_REQ`: client → daemon. Payload: `{client_id, lease_id, resume_token?}`.
- `REATTACH_ACK`: daemon → client. Payload: `{lease_id, lease_expiry_ts, plan_snapshot}`.

**Daemon state machine (tóm tắt):**

```
[Idle]
  └─(ATTACH_REQ)→ [Attached]

[Attached]
  ├─(HEARTBEAT within TTL)→ [Attached]
  ├─(DETACH)→ [Detached/Idle]
  └─(Heartbeat timeout)→ [Autonomous]

[Autonomous]
  ├─(REATTACH_REQ with valid lease_id or resume_token)→ [Attached]
  └─(Plan complete)→ [Idle]
```

**Hành vi khi mất heartbeat:**

- If `now > lease_expiry_ts`: daemon releases lease, enters **Autonomous** mode.
- Autonomous tiếp tục chạy plan cục bộ (nếu có) hoặc chờ plan mới.
- Telemetry/log vẫn ghi nội bộ để sync khi reattach.

**Hành vi khi reattach:**

- Validate `lease_id` hoặc `resume_token`.
- Trả `plan_snapshot` gồm `plan_id`, `current_step_id`, `step_status`, `last_seq`, `budgets_used`, `recent_logs`.

### A.8 Idempotent sequencing + cached ACK

**Cấu trúc lưu `last_seq`:**

```json
{
  "last_seq": {
    "plan_id_1": { "s1": 5, "s2": 2 },
    "plan_id_2": { "s1": 9 }
  }
}
```

**Logic xử lý duplicate:**

- Nếu `seq <= last_seq[plan_id][step_id]`: coi là duplicate, **không** thực thi lại.
- Trả lại `ACK` đã cache (hoặc dựng ACK mới từ trạng thái lưu).
- Nếu `seq == last_seq + 1`: xử lý bình thường và cập nhật `last_seq`.

**Format ACK có cache (gợi ý):**

```json
{
  "type": "STEP_ACK",
  "plan_id": "6c2b5e04-9a6a-4a2d-9f34-3bb7a2b3a1b1",
  "step_id": "s2",
  "seq": 7,
  "status": "accepted|duplicate|rejected",
  "result": { "ok": true, "data": {} },
  "server_ts": "2025-01-01T12:00:03Z"
}
```

**Pseudo-code xử lý message:**

```
function handle_step_message(msg):
    key = (msg.plan_id, msg.step_id)
    last = last_seq.get(key, 0)
    if msg.seq <= last:
        return cached_ack(key, msg.seq, status="duplicate")
    if msg.seq != last + 1:
        return ack(status="rejected", reason="seq_gap")
    result = execute_step(msg)
    last_seq[key] = msg.seq
    ack_cache[key][msg.seq] = build_ack(msg, result)
    checkpoint_state()
    return ack_cache[key][msg.seq]
```

### A.9 Telemetry message types (GET_PROGRESS/GET_LOGS)

**GET_PROGRESS (request/response):**

```json
{
  "type": "GET_PROGRESS",
  "plan_id": "6c2b5e04-9a6a-4a2d-9f34-3bb7a2b3a1b1"
}
```

```json
{
  "type": "PROGRESS",
  "plan_id": "6c2b5e04-9a6a-4a2d-9f34-3bb7a2b3a1b1",
  "current_step_id": "s2",
  "step_status": {
    "s1": "done",
    "s2": "running",
    "s3": "pending"
  },
  "budgets_used": { "time_ms": 42000, "touch_ops": 120, "retry_total": 3 },
  "started_at": "2025-01-01T12:00:00Z",
  "updated_at": "2025-01-01T12:00:03Z"
}
```

**GET_LOGS với cursor (request/response):**

```json
{
  "type": "GET_LOGS",
  "plan_id": "6c2b5e04-9a6a-4a2d-9f34-3bb7a2b3a1b1",
  "cursor": "log_000123"
}
```

```json
{
  "type": "LOGS",
  "plan_id": "6c2b5e04-9a6a-4a2d-9f34-3bb7a2b3a1b1",
  "next_cursor": "log_000130",
  "entries": [
    {
      "cursor": "log_000124",
      "event_type": "step_start",
      "step_id": "s2",
      "timestamp": "2025-01-01T12:00:02Z",
      "metrics": { "duration_ms": 0, "retries": 0 }
    },
    {
      "cursor": "log_000125",
      "event_type": "step_retry",
      "step_id": "s2",
      "timestamp": "2025-01-01T12:00:02Z",
      "reason": "guard_fail",
      "metrics": { "duration_ms": 120, "retries": 1 }
    }
  ]
}
```

### A.10 Telemetry screenshot API (GET_SCREENSHOT)

**GET_SCREENSHOT options (request):**

```json
{
  "type": "GET_SCREENSHOT",
  "plan_id": "6c2b5e04-9a6a-4a2d-9f34-3bb7a2b3a1b1",
  "rect": { "x": 0, "y": 0, "w": 800, "h": 600 },
  "scale": 0.5,
  "format": "jpg"
}
```

**Response (base64 payload):**

```json
{
  "type": "SCREENSHOT",
  "plan_id": "6c2b5e04-9a6a-4a2d-9f34-3bb7a2b3a1b1",
  "format": "jpg",
  "width": 400,
  "height": 300,
  "data_base64": "/9j/4AAQSkZJRgABAQAAAQABAAD..."
}
```

**Response (bytes payload, framed):**

- Header JSON (length-prefixed) + raw bytes:
  - `header_len` (4 bytes, big endian)
  - `header_json`
  - `image_bytes`

```json
{
  "type": "SCREENSHOT",
  "plan_id": "6c2b5e04-9a6a-4a2d-9f34-3bb7a2b3a1b1",
  "format": "png",
  "width": 400,
  "height": 300,
  "bytes_len": 81234
}
```

**Giới hạn kích thước (gợi ý):**

- `max_bytes`: 512KB–2MB cho WAN; vượt quá thì yêu cầu `scale` nhỏ hơn.
- `scale` default: 0.5 nếu không chỉ định.
- `rect` mặc định toàn màn hình nếu không truyền.

**Step schema (field gợi ý):**

- `step_id`: định danh duy nhất trong plan.
- `type`: loại step (touch, screenshot, ocr, image_match, sleep, ...).
- `payload`: dữ liệu tham số cho step (tuỳ loại).
- `guards`: danh sách guard cần pass trước khi chạy step.
- `retry`: `{ "max": int, "backoff_ms": int }`.
- `on_fail`: `{ "action": "abort|goto|skip", "target": "step_id?" }`.
- `budget`: `{ "time_ms": int }` per-step.

**Guard schema (field gợi ý):**

- `type`: `screen_match | text_match | app_is_foreground | time_window | custom`.
- `params`: object tham số, ví dụ:
  - `screen_match`: `{ "template": "login.png", "threshold": 0.92 }`
  - `text_match`: `{ "regex": "OTP\\s+\\d{6}" }`
  - `app_is_foreground`: `{ "bundle_id": "com.example.app" }`
  - `time_window`: `{ "start": "09:00", "end": "18:00", "tz": "Asia/Ho_Chi_Minh" }`

**Ví dụ Plan có 3 step (1 step có guard + retry):**

```json
{
  "plan_id": "6c2b5e04-9a6a-4a2d-9f34-3bb7a2b3a1b1",
  "plan_version": 1,
  "created_at": "2025-01-01T12:00:00Z",
  "budgets": { "time_ms": 180000, "retry_total": 10 },
  "steps": [
    {
      "step_id": "s1",
      "type": "app_foreground",
      "payload": { "bundle_id": "com.example.app" },
      "guards": [],
      "retry": { "max": 0, "backoff_ms": 0 },
      "on_fail": { "action": "abort" },
      "budget": { "time_ms": 5000 }
    },
    {
      "step_id": "s2",
      "type": "image_match",
      "payload": { "template_path": "/var/mobile/login.png", "acceptable_value": 0.9 },
      "guards": [
        { "type": "app_is_foreground", "params": { "bundle_id": "com.example.app" } }
      ],
      "retry": { "max": 3, "backoff_ms": 800 },
      "on_fail": { "action": "goto", "target": "s3" },
      "budget": { "time_ms": 12000 }
    },
    {
      "step_id": "s3",
      "type": "touch",
      "payload": { "type": "DOWN", "finger": 1, "x": 500, "y": 900 },
      "guards": [],
      "retry": { "max": 0, "backoff_ms": 0 },
      "on_fail": { "action": "abort" },
      "budget": { "time_ms": 2000 }
    }
  ],
  "on_fail": { "action": "abort" }
}
```

## Phase 1 — Plan schema & JobManager (on-device)

### Task 1.1 — Thiết kế Plan/Step/Guard schema
**Mục tiêu:** Định nghĩa JSON schema (plan_id, steps, retry, on_fail, budgets, guards).
**Trạng thái:** ✅ Đã triển khai lớp schema trong mã nguồn (`zxtouch.plan`).

**Prompt gợi ý**
```
Thiết kế JSON schema cho Plan/Step/Guard theo yêu cầu: steps + guards + retry + on_fail + budgets. Đưa ví dụ Plan có 3 step, trong đó 1 step có guard và retry.
```

### Task 1.2 — JobManager + State persistence
**Mục tiêu:** Có JobManager quản lý plan queue + lưu trạng thái ra disk.
**Trạng thái:** ⚠️ Đã có JobManager skeleton + JSON persistence (client-side).

**Prompt gợi ý**
```
Đề xuất cấu trúc lưu state (JSON/SQLite). Liệt kê trường cần persist: plan_id, current_step, last_seq, retry counters, lease info. Viết pseudo-code cho load/recover.
```

### Task 1.3 — Watchdog & Budget enforcement
**Mục tiêu:** Timeout từng step và toàn plan.

**Prompt gợi ý**
```
Thiết kế watchdog cho step timeout và plan budget. Đề xuất hành vi khi timeout (retry/on_fail/abort) và format log/telemetry.
```

---

## Phase 2 — Lease/Attach/Detach & Idempotent protocol

### Task 2.1 — Lease + Heartbeat
**Mục tiêu:** Protocol attach/detach; lease_ttl; auto-release.

**Prompt gợi ý**
```
Thiết kế message types cho ATTACH/HEARTBEAT/DETACH/REATTACH. Đề xuất state machine cho daemon khi mất heartbeat (autonomous) và khi reattach.
```

### Task 2.2 — Idempotent sequencing
**Mục tiêu:** plan_id/step_id/seq để chống duplicate WAN.
**Trạng thái:** ⚠️ Đã có IdempotentTracker helper (client-side).

**Prompt gợi ý**
```
Thiết kế cơ chế idempotent: cấu trúc lưu last_seq theo plan/step, logic xử lý duplicate, format ACK có cache. Viết pseudo-code cho xử lý message.
```

---

## Phase 3 — Telemetry API

### Task 3.1 — Progress & Log streaming
**Mục tiêu:** API để lấy progress/log.
**Trạng thái:** ⚠️ Đã có TelemetryStore skeleton (client-side).

**Prompt gợi ý**
```
Thiết kế message types cho GET_PROGRESS/GET_LOGS. Chỉ ra format progress payload và cursor log.
```

### Task 3.2 — Screenshot crop/downscale
**Mục tiêu:** API screenshot tùy chọn crop/scale.

**Prompt gợi ý**
```
Đề xuất API GET_SCREENSHOT với options (rect, scale, format). Mô tả cách encode trả về (base64/bytes) và giới hạn kích thước.
```

---

## Phase 4 — Desktop Orchestrator (Optional)

### Task 4.1 — Compiler: Script → Plan
**Mục tiêu:** Tool chuyển Python workflow thành Plan JSON.

**Prompt gợi ý**
```
Phác thảo pipeline compile script -> Plan JSON. Chỉ ra cách gắn guard/retry/on_fail và cách embed metadata (version, created_at).
```

### Task 4.2 — Reattach + State sync
**Mục tiêu:** Reattach sau WAN, sync tiến độ.

**Prompt gợi ý**
```
Thiết kế flow reattach: desktop gửi reattach, daemon trả snapshot state. Đề xuất payload snapshot và cách reconcile ở desktop.
```

---

## Phase 5 — Test scenarios & automation

### Task 5.1 — LAN streaming
**Prompt gợi ý**
```
Định nghĩa test case LAN: attach, submit plan, run steps, verify progress/log. Đề xuất metric latency & throughput.
```

### Task 5.2 — WAN jitter + duplicate packets
**Prompt gợi ý**
```
Định nghĩa test case WAN jitter: simulate packet delay/duplicate. Xác nhận idempotent seq không gây double touch.
```

### Task 5.3 — Disconnect/reconnect
**Prompt gợi ý**
```
Định nghĩa test case: mất mạng 30s khi đang chạy step dài. Daemon chạy autonomous, sau đó reattach và sync.
```

---

## Deliverables (MVP)

- Daemon on-device với JobManager, ResourceLock, Watchdog, persistence.
- Plan schema v1 + minimal step primitives (touch/sleep/screenshot).
- Attach/lease + idempotent seq.
- Telemetry: progress + logs.
- Desktop orchestrator tối thiểu: compile plan + submit + reattach.

## Ghi chú tương thích

- Không đổi API Python hiện tại; chỉ thêm methods mới cho Plan/Telemetry.
- Giữ socket port 6000; bổ sung message types mới.
