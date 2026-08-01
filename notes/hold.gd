extends Node2D
# ============================================================
# hold.gd — 长按音符（Hold）脚本
# Hold 由三段组成：头部（最下方）/ 身体（中间，可伸缩）/ 尾部（最上方）
# 三段共享一张竖直长纹理，通过 region_rect 各自裁剪对应区域
# 判定时刻：
#   头部（start）被判定后立即隐藏
#   身体（body）高度随时间线性缩短（scale.y 递减）
#   尾部（end）跟着身体上移
#   当尾部到达判定线时 Hold 结束并销毁
#
# 节点结构（hold.tscn）：
#   hold (Node2D)
#     ├── start (Sprite2D)  — 头部，旋转/缩放中心在底部
#     ├── body  (Sprite2D)  — 身体，旋转/缩放中心在顶部，scale.y 向下拉
#     └── end   (Sprite2D)  — 尾部，跟随 body 底部
# ============================================================

# 普通和多押高亮两张纹理（灰度图 + modulate 着色）
var hold_tex = preload("res://note_resource/hold.png")
var hold_mh_tex = preload("res://note_resource/hold_mh.png")

var length: float = 0        # Hold 身体的目标长度（像素），由 set_length() 设置
var mh: bool              # 是否多押高亮
var hide_start: bool      # 是否隐藏头部（判定后设为 true）

func _ready() -> void:
	# 开启 region 模式：三段 sprite 从同一张纹理中裁剪不同区域
	$start.region_enabled = true
	$body.region_enabled = true
	$end.region_enabled = true

	var tex_size
	var start_hight: float   # 头部高度（像素）
	var end_hight: float     # 尾部高度（像素）

	if mh:
		# 多押高亮版本的裁切尺寸（贴图布局不同）
		tex_size = hold_mh_tex.get_size()
		start_hight = 98
		end_hight = 98

		$start.texture = hold_mh_tex
		$body.texture = hold_mh_tex
		$end.texture = hold_mh_tex
	else:
		# 普通版本的裁切尺寸
		tex_size = hold_tex.get_size()
		start_hight = 50
		end_hight = 50

		$start.texture = hold_tex
		$body.texture = hold_tex
		$end.texture = hold_tex

	# 三段 region_rect 分配：
	#   头部（start）：贴图最底部 start_hight 像素
	#   身体（body）：头部以上、尾部以下，高度 = 总高 - start - end
	#   尾部（end）：贴图最顶部 end_hight 像素
	$start.region_rect = Rect2(0, tex_size.y - start_hight, tex_size.x, start_hight)
	$body.region_rect = Rect2(0, end_hight, tex_size.x, tex_size.y - start_hight - end_hight)
	$end.region_rect = Rect2(0, 0, tex_size.x, end_hight)

	# offset 调整缩放/旋转中心：
	#   start 中心在底部（向下隐藏时从底部缩）
	#   body 中心在顶部（向上拉伸时从顶部扩展）
	$start.offset = Vector2(0, $start.region_rect.size.y / 2.0)
	$body.offset = Vector2(0, -$body.region_rect.size.y / 2.0)


# ============================================================
# set_length — 设置 Hold 身体的目标高度
# l: 像素高度，Hold 身体会被 scale.y 拉伸到这个高度
# 尾部 position 据此重新计算，保持贴在身体底部
# ============================================================
func set_length(l: float): #长度为像素单位
	length = l
	# body 的 scale.y = 目标长度 / 原始高度 → 拉伸到正确尺寸
	var body_scale = length / $body.region_rect.size.y
	$body.scale = Vector2(1, body_scale)
	# end 跟在 body 底部：偏移 = -(body 拉伸后的高度) - (end 自身高度的一半)
	$end.offset = Vector2(0, -$body.region_rect.size.y * body_scale - $end.region_rect.size.y / 2.0)


# ============================================================
# set_hide_start — 设置头部 visible
# 判定时刻调用，将头部变透明（判定后头部消失，身体和尾巴继续）
# ============================================================
func set_hide_start(v: bool):
	hide_start = v
	$start.visible = not v
