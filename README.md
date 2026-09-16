# Rogue FPS Prototype · 肉鸽 FPS 最小原型

一个用 **Godot 4** 从零实现、**不依赖任何美术资源**（几何体 + 纯代码 UI）的第一人称射击 roguelike 原型。
目的很单纯：让你在一两天内理解"一个 FPS + 一个肉鸽循环"到底由哪些零件组成，然后自己往里加东西。

![游戏画面](docs/screenshot-gameplay.png)
![强化三选一](docs/screenshot-upgrade.png)

---

## 一、玩法

一局的流程是一条闭环：

```
随机生成场地 → 第 N 波敌人 → 全部清空 → 从 3 个词条里选 1 个强化 → 第 N+1 波（更强）
      ↑                                                                        │
      └────────────────── 死亡后按 R，重新随机一张地图 ──────────────────────┘
```

- **程序化关卡**：每局柱子、掩体、灯光位置全部重新随机，`reload_current_scene()` 就是"开新一局"。
- **波次与难度爬坡**：第 N 波敌人数量 `2 + round(N × 1.7)`（上限 24），血量 +19%/波、伤害 +10%/波。
- **三种敌人**：`普通`（红，均衡）、`冲锋`（黄，血少跑得快）、`重装`（紫，血厚打得疼），第 3 / 5 波开始出现。
- **12 个强化词条**：可叠加，乘算 / 加算混合，靠 `scripts/upgrades.gd` 一张表驱动。

### 操作

| 按键 | 功能 |
| --- | --- |
| `W A S D` | 移动 |
| `鼠标` | 转视角 |
| `鼠标左键` | 射击（按住连发） |
| `R` | 换弹（死亡后按 R 重开） |
| `Shift` | 疾跑 |
| `空格` | 跳跃 |
| `Esc` | 暂停 / 释放鼠标 |

---

## 二、跑起来

1. 打开 Godot 4.x（本项目在 **4.7.1** 上验证通过）。
2. `导入` → 选中本目录下的 `project.godot` → 导入并编辑。
3. 按 `F5`（或右上角 ▶）即可运行。

> 首次打开时 Godot 会生成 `.godot/` 缓存目录，已经在 `.gitignore` 里，**不要提交**。

### 命令行验证（可选）

不想开编辑器时，可以用无头模式自检，用来确认"工程本身没坏"：

```bash
# 导入资源
godot --headless --path . --import

# 自动打完几波，跑通「清波 → 三选一 → 下一波」全流程
godot --headless --path . --fixed-fps 60 --script res://tools/smoke_test.gd
```

`tools/smoke_test.gd` 会自己瞄准、开枪、秒怪、选强化，跑满 1800 帧后打印 `通过`。
**只要它通过，游戏逻辑就是好的**，剩下的问题只可能出在编辑器设置或分辨率上。

---

## 三、目录结构

```
.
├── project.godot               # 工程配置：主场景、窗口尺寸、输入映射（Input Map）
├── icon.svg                    # 图标
├── scenes/
│   ├── main.tscn               # 主场景，只挂了一个脚本，其余全部代码生成
│   ├── player.tscn             # 玩家：碰撞体 + 颈部 + 摄像机 + 枪械模型
│   ├── enemy.tscn              # 敌人：碰撞体 + 胶囊 mesh + 表现层
│   └── hud.tscn                # HUD 的 CanvasLayer 壳（process_mode = Always）
├── scripts/
│   ├── main.gd                 # ★ 关卡管理器：建场景、刷怪、波次、强化、结算
│   ├── player.gd               # ★ 玩家：移动、视角、射线枪、生命
│   ├── enemy.gd                # ★ 敌人：追击、避障、接触伤害、死亡
│   ├── hud.gd                  # ★ 全部界面（准星/血条/弹药/暂停/强化面板/结算）
│   └── upgrades.gd             # ★ 肉鸽词条池（数据 + 生效逻辑）
├── tools/
│   └── smoke_test.gd           # 无头冒烟测试
└── docs/                       # 截图
```

带 ★ 的 5 个文件就是整个游戏，一共不到 1000 行。建议按 `main → player → enemy → upgrades → hud` 的顺序读。

---

## 四、核心设计（改之前先看这段）

### 1. 碰撞层怎么分的

| 层 | 用途 | collision_layer | collision_mask |
| --- | --- | --- | --- |
| 1 | 地面 / 墙 / 柱子 | 1 | 0 |
| 2 | 玩家 | 2 | 1 |
| 3 | 敌人 | 4 | 1 |

玩家和敌人都**只和静态地形碰撞**，彼此不产生物理推挤 —— 这样敌人不会互相卡住，也不会把玩家顶飞。
伤害靠距离判定（`enemy.gd` 里 `dist < 1.7`）和射线（`player.gd` 里 `intersect_ray`，mask = `1 | 4`）实现。

### 2. 敌人为什么不会卡在柱子上

`enemy.gd` 每帧朝玩家方向打一条 1.5m 的射线，命中墙就取法线，把"朝向玩家的方向"和"墙的法线"混合：

```gdscript
dir = (dir + normal.normalized() * 1.6).normalized()
```

这是最省事的转向避障（steering），不需要烘焙导航网格（NavigationMesh）。敌人一多或者地形一复杂就该换 `NavigationAgent3D` + `NavigationRegion3D` 了。

### 3. 暂停和 UI 的关系（这里最容易踩坑）

- `hud.tscn` 的 `process_mode` 设成了 **Always**，所以 `get_tree().paused = true` 时它仍然收得到输入。
- 其他节点都是默认的 `Inherit`，会被暂停，于是强化面板一弹出来全场静止。
- 暂停只在 HUD 里管（`hud.gd` 的 `_input` 和 `show_upgrade_choices`），`main.gd` 不碰 `paused`。

如果你要加一个自己的 UI，记得把它的 `process_mode` 也设成 `Always`，否则暂停时点不动。

### 4. 加一个新强化词条（30 秒的事）

打开 `scripts/upgrades.gd`，两步：

```gdscript
# ① DATA 里加一条
{"id": "explosive", "name": "爆裂弹", "desc": "命中有 20% 概率造成范围伤害", "rarity": 3, "max": 3},

# ② apply() 的 match 里加一个分支
"explosive":
    player.explode_chance = player.explode_chance + 0.2
    title = "爆裂弹"
```

`max` 是叠加上限，叠满后不会再被抽到；`rarity` 只影响卡片边框颜色（1 普通 / 2 稀有 / 3 传说）。

### 5. 想调手感，改这些数

都在 `player.gd` 顶部的 `@export` 里，编辑器选中 Player 节点就能直接拖：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `base_speed` | 6.2 | 移动速度 |
| `weapon_damage` | 18 | 单发伤害 |
| `fire_rate` | 7.5 | 每秒射击次数 |
| `spread_deg` | 2.0 | 散布角度 |
| `mag_size` / `reload_time` | 24 / 1.2 | 弹匣与换弹 |
| `max_health` | 100 | 生命上限 |

---

## 五、导出成 exe

1. 编辑器菜单 `项目 → 导出`。
2. 点 `添加…` → 选 `Windows Desktop`。
3. 如果提示缺少导出模板，点 `管理导出模板` → 下载对应版本的模板并安装。
4. 选好输出路径（例如 `build/RogueFPS.exe`），点 `导出项目`。

> `build/` 已经在 `.gitignore` 里。**不要把 .exe 提交到仓库**：GitHub 单文件上限 100MB，Godot 打出来的包很容易超。
> 想让别人直接玩，正确做法是发 GitHub **Release**（见下一节）。

---

## 六、仓库与后续推送

**仓库已经建好并推送完成：** https://github.com/yubinrui2005-droid/iloveu

日常改完代码，只需要三条命令：

```bash
cd H:/fps
git add -A
git commit -m "描述这次改了什么"
git push
```

`git push` 之后加 `-u` 只需第一次用，之后直接 `git push` 即可。

### 关于认证（Windows 上最容易卡住的一步）

GitHub 不支持账号密码推送。本机的情况是：**已存的 GitHub 凭据放在 Windows 凭据管理器里**，
必须让 git 用 `wincred` 助手去读它。全局配置已经设好了：

```bash
git config --global credential.helper wincred   # 已执行
```

> **踩坑记录**：本机 git 的系统默认助手是 `credential.helper=helper-selector`，
> 它是个**需要交互选择**的助手，在非交互终端（脚本、自动化工具）里会直接挂死、无任何输出。
> 如果哪天 `git push` 又卡住不动，先检查 `git config --global credential.helper` 是不是被改回去了。

如果以后换账号或 token 失效，清掉旧凭据重来：

```bash
# 删除已存的 github 凭据
cmdkey /delete:LegacyGeneric:target=git:https://github.com
git push     # 会重新询问用户名和 token
```

**其他两种认证方式（备用）**

- **Personal Access Token（PAT）**：GitHub → 头像 → `Settings` → `Developer settings` →
  `Personal access tokens` → `Tokens (classic)` → `Generate new token (classic)`，
  勾 `repo`，复制 `ghp_...`；推送时用户名填 GitHub 用户名，密码处粘贴 token。
- **SSH 密钥**：
  ```bash
  ssh-keygen -t ed25519 -C "你的邮箱"
  # 一路回车，把 ~/.ssh/id_ed25519.pub 内容贴到 GitHub → Settings → SSH and GPG keys
  ssh -T git@github.com
  git remote set-url origin git@github.com:yubinrui2005-droid/iloveu.git
  ```

### 想省掉手写 URL 的麻烦？装 GitHub CLI

本机**没有装 `gh`**。装完之后一行就能建仓库 + 推送：

```bash
winget install --id GitHub.cli
gh auth login
gh repo create <仓库名> --public --source=. --remote=origin --push
```

### 5. 让项目更好看：加截图和 Release

- README 里的图片：把截图丢进 `docs/`，用 `![说明](docs/xxx.png)` 引用即可（本项目已经这么做了）。
- 发布可玩版本：`git tag v0.1.0 && git push origin v0.1.0`，然后在 GitHub 仓库页 `Releases → Draft a new release`，把导出的 zip 当附件上传。

### 6. 常见坑

| 现象 | 原因 / 解决 |
| --- | --- |
| 推送被拒：`file is 105.00 MB` | 提交了导出产物。删掉大文件，确认 `.gitignore` 生效后重新提交 |
| `.godot/` 被提交了 | `.gitignore` 没生效（可能仓库已经跟踪了它）：`git rm -r --cached .godot` |
| 换行符警告 / `.tscn` 冲突 | 已放 `.gitattributes` 统一用 LF |
| `src refspec main does not match any` | 还没提交过，先 `git add -A && git commit -m "init"` |
| 队友克隆后打开报错 | 让对方用**同版本的 Godot** 打开；Godot 的小版本差异会改 `project.godot` |

---

## 七、下一步可以加什么

按"性价比"从高到低排：

1. **音效**：枪声、命中、死亡。不用素材也能做 —— `AudioStreamGenerator` 程序化合成，或者去 freesound.org 找 CC0 音源。
2. **Boss 波**：每 5 波刷一只大怪，血条挂在 HUD 顶部。
3. **多层地图 / 房间流**：把现在的单张竞技场换成"清完一间开门去下一间"，更接近《枪火重生》《Risk of Rain》的体感。
4. **武器切换**：把 `player.gd` 里的武器数值抽成一个 `Weapon` Resource，就能做霰弹枪 / 步枪 / 狙击切换。
5. **真正的导航**：地形复杂后把 `enemy.gd` 的转向避障换成 `NavigationRegion3D` + `NavigationAgent3D`。
6. **存档 / 排行榜**：肉鸽的爽点之一，用 `FileAccess` 存 JSON 就行。
7. **Web 导出**：Godot 可以直接导出 HTML5，传到 GitHub Pages 让人在线玩（注意：Web 版对手柄和全屏支持一般）。

---

## 八、参考

- Godot 官方文档：https://docs.godotengine.org/zh-cn/4.x/
- `CharacterBody3D` 与 `move_and_slide`：https://docs.godotengine.org/zh-cn/4.x/classes/class_characterbody3d.html
- 射线检测 `intersect_ray`：https://docs.godotengine.org/zh-cn/4.x/tutorials/physics/ray-casting.html

---

## License

MIT，见 [LICENSE](LICENSE)。
