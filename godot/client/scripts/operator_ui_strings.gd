class_name OperatorUIStrings
extends RefCounted

const TITLE := "作业菜单"
const GUIDE_TITLE := "掌握你的挖掘机"
const GUIDE_INTRO := "入场后即可操纵。让铲斗接触地面进行挖掘，收斗运土、翻斗卸土；无需额外的挖土按钮。"
const GUIDE_KEYBOARD := "键盘与鼠标 · ISO 操纵布局\n\nW / S   小臂外伸 / 内收     A / D   左右回转\nI / K   大臂下降 / 抬升     J / L   收斗 / 卸土\nR / F   左履带前进 / 后退     Y / H   右履带前进 / 后退\n\n1–5   切换视角     C   复位视角\n鼠标中键拖动环绕 · 滚轮缩放\nEsc   打开 / 关闭菜单     F8   重新开始作业"
const GUIDE_GAMEPAD := "手柄 · ISO 操纵布局\n\n左摇杆   左右回转 / 小臂外伸内收\n右摇杆   大臂升降 / 收斗卸土\nLT / LB   左履带前进 / 后退\nRT / RB   右履带前进 / 后退\n\n十字键   切换视角     R3   复位视角\n菜单键   打开 / 关闭菜单\n菜单内：十字键导航 · A 确认 · B 返回 · LB / RB 切换页面"
const GUIDE_RECOVERY := "Reset 和切换机型会清空当前地形改动与斗内土量。确认后松开操纵输入，即可开始新作业。"
const CONTROL_HINT_KEYBOARD := "WASD  回转 / 小臂   ·   IJKL  大臂 / 铲斗   ·   R/F、Y/H  履带"
const CONTROL_HINT_GAMEPAD := "左摇杆  回转 / 小臂   ·   右摇杆  大臂 / 铲斗   ·   扳机与肩键  履带"
const SOIL_AUTOMATIC_HINT := "挖掘、运土、卸土均由铲斗姿态与接触自动完成。"

const BUTTON_RESET := "重新开始作业    /    Reset"
const BUTTON_GUIDE := "Controls"
const BUTTON_ADVANCED := "Advanced"
const BUTTON_CLOSE := "返回设备设置"
const BUTTON_RESET_VIEW := "复位视角"
const BUTTON_MUTE_AUDIO := "静音"
const BUTTON_TEST_GRAPHICS := "Test Grid"
const BUTTON_COLLAPSE_PANEL := "Hide panel"
const BUTTON_EXPAND_PANEL := "Controls"

const WARNING_FOCUS := "窗口未激活 · 点击游戏后继续操纵。"
const WARNING_PAUSED := "作业已暂停 · 返回驾驶后继续。"
const WARNING_STOPPED := "设备尚未就绪。请检查高级工具中的状态。"
const WARNING_GATEWAY := "Optional gateway is unavailable — reconnect or return to local mode."
const WARNING_NEUTRAL := "请先松开摇杆、扳机和操纵键，再继续驾驶。"
const WARNING_OVERFLOW := "铲斗已满 · 收斗或卸土后继续。"
const WARNING_NONE := "Ready"


static func model_name(model_id: String) -> String:
	return {"sy205": "SANY SY205", "sy135": "SANY SY135"}.get(model_id, model_id.to_upper())


static func lifecycle_text(value: String) -> String:
	return {"running": "运行中", "paused": "已暂停", "stopped": "未就绪"}.get(value, value.to_upper())


static func fill_text(fill_ratio: float) -> String:
	if fill_ratio <= 0.02:
		return "EMPTY"
	if fill_ratio >= 0.85:
		return "FULL"
	return "PARTIAL"


static func operation_text(value: String) -> String:
	return {
		"idle": "准备就绪",
		"contact": "铲斗接触",
		"scrape": "平整地面",
		"cut": "正在挖掘",
		"load": "正在装斗",
		"carry": "正在运土",
		"dump": "正在卸土",
		"spill": "土方散落",
		"overflow": "铲斗已满",
	}.get(value, value.replace("_", " ").to_upper())


static func reset_confirmation() -> String:
	return "重新开始当前作业？\n\n地形改动和斗内土量将被清空，此操作无法撤销。\n复位后松开操纵输入，即可继续驾驶。"


static func model_confirmation(model_id: String) -> String:
	return "切换至 %s？\n\n当前地形改动与斗内土量将被清空。切换后松开操纵输入，即可开始新作业。" % model_name(model_id)
