# 《混乱快递》技术设计文档 (TDD)

> **版本**：v0.1  
> **日期**：2026-03-20  
> **引擎**：Godot 4.x  
> **语言**：GDScript 2.0 (核心逻辑) + C# (如有性能需求)

---

## 一、项目架构

### 1.1 目录结构

```
chaos-delivery/
├── project.godot
├── assets/
│   ├── models/           # 3D模型 (.glb/.gltf)
│   ├── textures/         # 贴图
│   ├── audio/            # 音效和音乐
│   ├── fonts/            # 字体
│   └── shaders/          # 自定义着色器
├── src/
│   ├── autoload/         # 自动加载脚本
│   ├── components/       # 可复用组件
│   ├── entities/         # 游戏实体
│   ├── systems/          # 游戏系统
│   ├── ui/               # UI脚本
│   ├── network/          # 网络相关
│   └── utils/            # 工具类
├── scenes/               # 场景文件
│   ├── levels/           # 关卡场景
│   ├── entities/         # 实体场景
│   └── ui/               # UI场景
└── resources/            # 资源文件
    ├── orders/           # 订单数据
    ├── packages/         # 包裹配置
    └── events/           # 事件配置
```

### 1.2 自动加载 (AutoLoad)

| 名称 | 脚本 | 职责 |
|------|------|------|
| **EventBus** | `autoload/event_bus.gd` | 全局事件总线 |
| **GameState** | `autoload/game_state.gd` | 游戏状态管理 |
| **NetworkManager** | `autoload/network_manager.gd` | 网络连接管理 |
| **AudioManager** | `autoload/audio_manager.gd` | 音频管理 |
| **SaveManager** | `autoload/save_manager.gd` | 存档管理 |
| **InputManager** | `autoload/input_manager.gd` | 输入映射管理 |

---

## 二、核心系统实现

### 2.1 事件总线 (EventBus)

```gdscript
## autoload/event_bus.gd
extends Node

# ==================== 包裹事件 ====================
signal package_grabbed(package: Package, by_player: Player)
signal package_dropped(package: Package, position: Vector3, velocity: Vector3)
signal package_damaged(package: Package, damage_type: String)
signal package_scanned(package: Package, destination: String)
signal package_loaded(package: Package, vehicle: Vehicle)

# ==================== 订单事件 ====================
signal order_received(order: OrderData)
signal order_completed(order: OrderData, quality: float, reward: int)
signal order_failed(order: OrderData, reason: String)
signal order_updated(order: OrderData, time_remaining: float)

# ==================== 玩家事件 ====================
signal player_joined(player_id: int, player_name: String)
signal player_left(player_id: int)
signal player_spawned(player: Player)
signal player_died(player: Player)
signal perfect_catch(catcher: Player, thrower: Player)

# ==================== 游戏流程事件 ====================
signal phase_changed(new_phase: GamePhase, old_phase: GamePhase)
signal event_triggered(event_type: String, duration: float)
signal event_ended(event_type: String)
signal score_changed(new_score: int, delta: int)
signal gold_changed(new_amount: int, delta: int)

# ==================== 网络事件 ====================
signal host_migrated(new_host_id: int)
signal player_disconnected(player_id: int, was_host: bool)
signal connection_lost()
signal connection_restored()

enum GamePhase {
    LOBBY,
    PREPARATION,
    WORKING,
    SETTLEMENT,
    PAUSED
}
```

### 2.2 游戏状态管理 (GameState)

```gdscript
## autoload/game_state.gd
extends Node

# 当前游戏状态
var current_phase: EventBus.GamePhase = EventBus.GamePhase.LOBBY
var current_level: String = ""
var game_time_elapsed: float = 0.0

# 玩家数据（本地）
var local_player_id: int = -1
var local_player_name: String = "Player"

# 本局数据（运行时）
var current_orders: Array[OrderData] = []
var completed_orders: int = 0
var failed_orders: int = 0
var current_gold: int = 0
var current_score: int = 0
var perfect_catches: int = 0

# 持久化数据
var player_profile: PlayerProfile

func _ready() -> void:
    player_profile = SaveManager.load_profile()

func start_game(level_name: String) -> void:
    current_level = level_name
    current_phase = EventBus.GamePhase.PREPARATION
    game_time_elapsed = 0.0
    _reset_session_data()
    EventBus.phase_changed.emit(current_phase, EventBus.GamePhase.LOBBY)

func _reset_session_data() -> void:
    current_orders.clear()
    completed_orders = 0
    failed_orders = 0
    current_gold = 0
    current_score = 0
    perfect_catches = 0

func add_gold(amount: int, reason: String) -> void:
    current_gold += amount
    EventBus.gold_changed.emit(current_gold, amount)

func change_phase(new_phase: EventBus.GamePhase) -> void:
    var old_phase := current_phase
    current_phase = new_phase
    EventBus.phase_changed.emit(new_phase, old_phase)
```

### 2.3 网络管理器 (NetworkManager)

```gdscript
## autoload/network_manager.gd
extends Node

const DEFAULT_PORT: int = 7777
const MAX_PLAYERS: int = 4
const HEARTBEAT_INTERVAL: float = 1.0
const HEARTBEAT_TIMEOUT: float = 5.0

var is_host: bool = false
var is_connected: bool = false
var host_id: int = 1

# 玩家连接信息
var connected_peers: Dictionary = {}  # {player_id: peer_info}
var last_heartbeat: Dictionary = {}   # {player_id: timestamp}

# 网络状态快照
var state_snapshots: Array[Dictionary] = []  # 用于主机迁移

@onready var multiplayer_peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()

func _ready() -> void:
    multiplayer.peer_connected.connect(_on_peer_connected)
    multiplayer.peer_disconnected.connect(_on_peer_disconnected)
    multiplayer.connected_to_server.connect(_on_connected_to_server)
    multiplayer.connection_failed.connect(_on_connection_failed)
    multiplayer.server_disconnected.connect(_on_server_disconnected)

# ==================== 主机功能 ====================

func create_host(port: int = DEFAULT_PORT) -> Error:
    var err := multiplayer_peer.create_server(port, MAX_PLAYERS)
    if err != OK:
        return err
    
    multiplayer.multiplayer_peer = multiplayer_peer
    is_host = true
    is_connected = true
    host_id = multiplayer.get_unique_id()
    GameState.local_player_id = host_id
    
    _start_heartbeat_timer()
    return OK

# ==================== 客机功能 ====================

func join_host(address: String, port: int = DEFAULT_PORT) -> Error:
    var err := multiplayer_peer.create_client(address, port)
    if err != OK:
        return err
    
    multiplayer.multiplayer_peer = multiplayer_peer
    is_host = false
    return OK

# ==================== RPC方法 ====================

@rpc("authority", "call_local", "reliable")
func sync_game_state(state_data: Dictionary) -> void:
    if not is_host:
        _apply_game_state(state_data)

@rpc("any_peer", "call_remote", "reliable")
func request_grab_package(package_id: int) -> void:
    if not is_host:
        return
    # 主机验证并处理
    _validate_and_process_grab(multiplayer.get_remote_sender_id(), package_id)

@rpc("authority", "call_local", "reliable")
func confirm_package_grabbed(package_id: int, player_id: int) -> void:
    EventBus.package_grabbed.emit(_get_package_by_id(package_id), _get_player_by_id(player_id))

@rpc("any_peer", "call_remote", "reliable")
func heartbeat_response() -> void:
    var sender_id := multiplayer.get_remote_sender_id()
    last_heartbeat[sender_id] = Time.get_unix_time_from_system()

# ==================== 主机迁移 ====================

func initiate_host_migration() -> void:
    if connected_peers.is_empty():
        return
    
    # 选择ID最小的玩家作为新主机
    var new_host_id: int = connected_peers.keys().min()
    
    rpc("migrate_host", new_host_id, _create_state_snapshot())

@rpc("authority", "call_local", "reliable")
func migrate_host(new_host_id: int, snapshot: Dictionary) -> void:
    host_id = new_host_id
    if GameState.local_player_id == new_host_id:
        is_host = true
        _restore_from_snapshot(snapshot)
    EventBus.host_migrated.emit(new_host_id)

# ==================== 信号回调 ====================

func _on_peer_connected(id: int) -> void:
    connected_peers[id] = {"id": id, "joined_at": Time.get_unix_time_from_system()}
    last_heartbeat[id] = Time.get_unix_time_from_system()
    EventBus.player_joined.emit(id, "Player_%d" % id)

func _on_peer_disconnected(id: int) -> void:
    var was_host := (id == host_id)
    connected_peers.erase(id)
    last_heartbeat.erase(id)
    EventBus.player_disconnected.emit(id, was_host)
    
    if was_host and not connected_peers.is_empty():
        initiate_host_migration()

func _on_server_disconnected() -> void:
    is_connected = false
    EventBus.connection_lost.emit()
```

---

## 三、实体组件设计

### 3.1 组件基类

```gdscript
## components/component_base.gd
class_name ComponentBase
extends Node

## 所有组件的基类，提供通用的生命周期管理

@export var enabled: bool = true:
    set(value):
        enabled = value
        _set_enabled(value)

func _set_enabled(value: bool) -> void:
    pass

func get_entity() -> Node:
    return get_parent()
```

### 3.2 可抓取组件 (GrabbableComponent)

```gdscript
## components/grabbable_component.gd
class_name GrabbableComponent
extends ComponentBase

signal grabbed(by: Player)
signal dropped(position: Vector3, velocity: Vector3)
signal throw_started(direction: Vector3, power: float)

@export var weight: float = 1.0  # 影响携带者移速
@export var can_be_thrown: bool = true
@export var throw_charge_time: float = 1.2
@export var min_throw_distance: float = 2.5
@export var max_throw_distance: float = 7.0

var is_held: bool = false
var holder: Player = null
var throw_charge: float = 0.0

func grab(by: Player) -> bool:
    if is_held or not enabled:
        return false
    
    is_held = true
    holder = by
    _setup_held_state()
    grabbed.emit(by)
    return true

func drop() -> void:
    if not is_held:
        return
    
    var drop_pos := global_position
    var drop_vel := Vector3.ZERO
    
    is_held = false
    holder = null
    _setup_dropped_state(drop_pos, drop_vel)
    dropped.emit(drop_pos, drop_vel)

func throw(direction: Vector3, charge: float) -> void:
    if not is_held or not can_be_thrown:
        return
    
    var throw_power := lerpf(min_throw_distance, max_throw_distance, charge)
    var throw_vel := direction.normalized() * _calculate_throw_velocity(throw_power)
    
    is_held = false
    var prev_holder := holder
    holder = null
    
    _setup_thrown_state(throw_vel)
    throw_started.emit(direction, charge)
    
    # 进入可接状态
    _enable_catchable_state(prev_holder)

func _setup_held_state() -> void:
    # 禁用物理，跟随持有者
    var body := get_entity() as RigidBody3D
    if body:
        body.freeze = true
        body.top_level = false
        reparent(holder.get_hold_point())
        position = Vector3.ZERO

func _setup_dropped_state(pos: Vector3, vel: Vector3) -> void:
    var body := get_entity() as RigidBody3D
    if body:
        reparent(get_tree().current_scene)
        global_position = pos
        body.freeze = false
        body.linear_velocity = vel

func _setup_thrown_state(velocity: Vector3) -> void:
    var body := get_entity() as RigidBody3D
    if body:
        reparent(get_tree().current_scene)
        body.freeze = false
        body.linear_velocity = velocity

func _enable_catchable_state(thrower: Player) -> void:
    # 1.5秒内可被接住
    var catchable := CatchableComponent.new()
    catchable.thrower = thrower
    catchable.catch_window = 1.5
    get_entity().add_child(catchable)

func _calculate_throw_velocity(distance: float) -> float:
    # 抛物线计算
    var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
    var angle := deg_to_rad(45.0)  # 45度角投掷
    return sqrt((distance * gravity) / sin(2 * angle))
```

### 3.3 易碎组件 (FragileComponent)

```gdscript
## components/fragile_component.gd
class_name FragileComponent
extends ComponentBase

signal broken()

@export var max_impact_velocity: float = 5.0
@export var break_particles: PackedScene

var is_broken: bool = false

func _ready() -> void:
    # 监听父节点的碰撞
    var body := get_entity() as RigidBody3D
    if body:
        body.body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node) -> void:
    if is_broken:
        return
    
    var parent_body := get_entity() as RigidBody3D
    if parent_body and parent_body.linear_velocity.length() > max_impact_velocity:
        _break()

func _break() -> void:
    is_broken = true
    
    # 播放特效
    if break_particles:
        var particles := break_particles.instantiate() as GPUParticles3D
        get_tree().current_scene.add_child(particles)
        particles.global_position = global_position
        particles.emitting = true
    
    # 通知事件总线
    EventBus.package_damaged.emit(get_entity(), "fragile_broken")
    broken.emit()
    
    # 销毁或替换为破损模型
    get_entity().queue_free()
```

### 3.4 急件组件 (UrgentComponent)

```gdscript
## components/urgent_component.gd
class_name UrgentComponent
extends ComponentBase

signal time_expired()
signal time_warning()  # 剩余10秒时触发

@export var time_limit: float = 60.0

var time_remaining: float:
    set(value):
        time_remaining = max(0.0, value)
        if time_remaining <= 10.0 and not _warning_triggered:
            _warning_triggered = true
            time_warning.emit()
        if time_remaining <= 0.0 and not _expired_triggered:
            _expired_triggered = true
            time_expired.emit()

var _warning_triggered: bool = false
var _expired_triggered: bool = false

func _process(delta: float) -> void:
    if enabled and not _expired_triggered:
        time_remaining -= delta

func _ready() -> void:
    time_remaining = time_limit
```

### 3.5 可接组件 (CatchableComponent)

```gdscript
## components/catchable_component.gd
class_name CatchableComponent
extends ComponentBase

signal caught(by: Player)
signal catch_window_expired()

var thrower: Player = null
var catch_window: float = 1.5
var _timer: float = 0.0

func _process(delta: float) -> void:
    _timer += delta
    if _timer >= catch_window:
        catch_window_expired.emit()
        queue_free()

func try_catch(by: Player) -> bool:
    if by == thrower:
        return false  # 不能接自己扔的
    
    # 检查距离和时机
    var distance := by.global_position.distance_to(global_position)
    if distance > 2.0:  # 最大接球距离
        return false
    
    # 成功接住
    caught.emit(by)
    EventBus.perfect_catch.emit(by, thrower)
    
    # 转移所有权
    var grabbable := get_entity().get_node_or_null("GrabbableComponent") as GrabbableComponent
    if grabbable:
        grabbable.grab(by)
    
    queue_free()
    return true
```

---

## 四、实体设计

### 4.1 玩家实体 (Player)

```gdscript
## entities/player.gd
class_name Player
extends CharacterBody3D

@export var move_speed: float = 4.5
@export var rotation_speed: float = 360.0  # 度/秒
@export var player_id: int = -1
@export var player_name: String = "Player"

# 组件引用
@onready var grab_point: Marker3D = $GrabPoint
@onready var interaction_ray: RayCast3D = $InteractionRay
@onready var animation_player: AnimationPlayer = $AnimationPlayer

# 状态
var held_package: Package = null
var is_charging_throw: bool = false
var throw_charge: float = 0.0
var current_speed_modifier: float = 1.0

func _ready() -> void:
    add_to_group("players")
    
    # 只有本地玩家接收输入
    if player_id == GameState.local_player_id:
        set_process_input(true)
    else:
        set_process_input(false)

func _physics_process(delta: float) -> void:
    if player_id == GameState.local_player_id:
        _handle_local_input(delta)
    
    _apply_velocity(delta)
    move_and_slide()

func _handle_local_input(delta: float) -> void:
    # 移动输入
    var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
    var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
    
    if direction.length() > 0:
        velocity.x = direction.x * move_speed * current_speed_modifier
        velocity.z = direction.z * move_speed * current_speed_modifier
        
        # 平滑转向
        var target_rotation := atan2(direction.x, direction.z)
        rotation.y = lerp_angle(rotation.y, target_rotation, rotation_speed * delta / 360.0)
    else:
        velocity.x = move_toward(velocity.x, 0, move_speed * delta * 5.0)
        velocity.z = move_toward(velocity.z, 0, move_speed * delta * 5.0)
    
    # 抓取/投掷
    if Input.is_action_just_pressed("grab"):
        _on_grab_pressed()
    elif Input.is_action_just_released("grab"):
        _on_grab_released()
    
    # 蓄力
    if is_charging_throw and held_package:
        throw_charge = min(throw_charge + delta / held_package.grabbable.throw_charge_time, 1.0)

func _on_grab_pressed() -> void:
    if held_package:
        # 开始蓄力投掷
        is_charging_throw = true
        throw_charge = 0.0
    else:
        # 尝试抓取
        _try_grab()

func _on_grab_released() -> void:
    if is_charging_throw and held_package:
        # 执行投掷
        _throw_package()
    is_charging_throw = false
    throw_charge = 0.0

func _try_grab() -> void:
    # 射线检测可抓取物体
    if interaction_ray.is_colliding():
        var collider := interaction_ray.get_collider()
        var package := collider.get_parent() as Package
        
        if package and package.grabbable:
            # 网络同步：通知主机
            if not NetworkManager.is_host:
                NetworkManager.request_grab_package.rpc_id(1, package.get_instance_id())
            else:
                _grab_package(package)

func _grab_package(package: Package) -> void:
    if package.grabbable.grab(self):
        held_package = package
        _update_speed_modifier()
        animation_player.play("grab")

func _throw_package() -> void:
    if not held_package:
        return
    
    var throw_dir := -transform.basis.z  # 向前投掷
    held_package.grabbable.throw(throw_dir, throw_charge)
    
    held_package = null
    _update_speed_modifier()
    animation_player.play("throw")

func _update_speed_modifier() -> void:
    if held_package:
        current_speed_modifier = 1.0 - (held_package.grabbable.weight * 0.15)
    else:
        current_speed_modifier = 1.0

func get_hold_point() -> Marker3D:
    return grab_point

func _apply_velocity(delta: float) -> void:
    # 重力
    if not is_on_floor():
        velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity") * delta
    else:
        velocity.y = 0.0
```

### 4.2 包裹实体 (Package)

```gdscript
## entities/package.gd
class_name Package
extends RigidBody3D

@export var package_data: PackageData

# 组件（可选，根据类型动态添加）
var grabbable: GrabbableComponent
var fragile: FragileComponent
var urgent: UrgentComponent
var hazardous: HazardousComponent
var living: LivingComponent

# 视觉
@onready var mesh_instance: MeshInstance3D = $MeshInstance3D
@onready var label_sprite: Sprite3D = $LabelSprite

func _ready() -> void:
    add_to_group("packages")
    _setup_components()
    _update_visuals()

func _setup_components() -> void:
    # 所有包裹都有可抓取组件
    grabbable = GrabbableComponent.new()
    add_child(grabbable)
    
    # 根据数据添加其他组件
    if package_data:
        if package_data.is_fragile:
            fragile = FragileComponent.new()
            add_child(fragile)
        
        if package_data.is_urgent:
            urgent = UrgentComponent.new()
            urgent.time_limit = package_data.time_limit
            add_child(urgent)
        
        if package_data.is_hazardous:
            hazardous = HazardousComponent.new()
            add_child(hazardous)
        
        if package_data.is_living:
            living = LivingComponent.new()
            add_child(living)

func _update_visuals() -> void:
    if not package_data:
        return
    
    # 应用材质
    if package_data.material:
        mesh_instance.material_override = package_data.material
    
    # 更新标签
    label_sprite.texture = package_data.label_texture

func get_package_type() -> String:
    if package_data:
        return package_data.type_name
    return "unknown"
```

---

## 五、数据资源

### 5.1 包裹数据 (PackageData)

```gdscript
## resources/package_data.gd
class_name PackageData
extends Resource

@export var type_name: String = "normal"
@export var display_name: String = "普通包裹"
@export var description: String = ""

# 类型标记
@export var is_fragile: bool = false
@export var is_urgent: bool = false
@export var is_hazardous: bool = false
@export var is_living: bool = false
@export var is_large: bool = false

# 物理属性
@export var weight: float = 1.0
@export var size_scale: Vector3 = Vector3.ONE

# 急件专用
@export var time_limit: float = 60.0

# 视觉
@export var mesh: Mesh
@export var material: Material
@export var label_texture: Texture2D
@export var icon: Texture2D

# 效果
@export var break_effect: PackedScene
@export var spawn_effect: PackedScene
```

### 5.2 订单数据 (OrderData)

```gdscript
## resources/order_data.gd
class_name OrderData
extends Resource

@export var order_id: String = ""
@export var destination: String = ""
@export var destination_code: String = ""  # 用于扫描匹配

# 包裹要求
@export var required_types: Array[String] = []  # 需要的包裹类型
@export var required_count: int = 1
@export var allow_substitutes: bool = false

# 时间限制
@export var is_urgent: bool = false
@export var time_limit: float = 120.0

# 奖励
@export var base_reward: int = 30
@export var early_bonus: int = 10
@export var urgent_bonus: int = 20

# 视觉
@export var destination_icon: Texture2D
@export var card_color: Color = Color.WHITE
```

---

## 六、输入映射

### 6.1 输入动作配置 (project.godot)

```ini
[input]

move_left={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":0,"physical_keycode":65,"key_label":0,"unicode":97,"echo":false,"script":null)
, Object(InputEventJoypadMotion,"resource_local_to_scene":false,"resource_name":"","device":-1,"axis":0,"axis_value":-1.0,"script":null)
]
}
move_right={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":0,"physical_keycode":68,"key_label":0,"unicode":100,"echo":false,"script":null)
, Object(InputEventJoypadMotion,"resource_local_to_scene":false,"resource_name":"","device":-1,"axis":0,"axis_value":1.0,"script":null)
]
}
move_forward={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":0,"physical_keycode":87,"key_label":0,"unicode":119,"echo":false,"script":null)
, Object(InputEventJoypadMotion,"resource_local_to_scene":false,"resource_name":"","device":-1,"axis":1,"axis_value":-1.0,"script":null)
]
}
move_backward={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":0,"physical_keycode":83,"key_label":0,"unicode":115,"echo":false,"script":null)
, Object(InputEventJoypadMotion,"resource_local_to_scene":false,"resource_name":"","device":-1,"axis":1,"axis_value":1.0,"script":null)
]
}
grab={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":0,"physical_keycode":32,"key_label":0,"unicode":32,"echo":false,"script":null)
, Object(InputEventJoypadMotion,"resource_local_to_scene":false,"resource_name":"","device":-1,"axis":5,"axis_value":1.0,"script":null)
]
}
interact={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":0,"physical_keycode":69,"key_label":0,"unicode":101,"echo":false,"script":null)
, Object(InputEventJoypadButton,"resource_local_to_scene":false,"resource_name":"","device":-1,"button_index":2,"pressure":0.0,"pressed":false,"script":null)
]
}
scan={
"deadzone": 0.5,
"events": [Object(InputEventMouseButton,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"button_mask":1,"position":Vector2(0, 0),"global_position":Vector2(0, 0),"factor":1.0,"button_index":1,"canceled":false,"pressed":false,"double_click":false,"script":null)
, Object(InputEventJoypadButton,"resource_local_to_scene":false,"resource_name":"","device":-1,"button_index":0,"pressure":0.0,"pressed":false,"script":null)
]
}
pause={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":0,"physical_keycode":4194305,"key_label":0,"unicode":0,"echo":false,"script":null)
, Object(InputEventJoypadButton,"resource_local_to_scene":false,"resource_name":"","device":-1,"button_index":6,"pressure":0.0,"pressed":false,"script":null)
]
}
```

---

## 七、项目设置

### 7.1 关键项目设置 (project.godot)

```ini
; 应用配置
application/config/name="混乱快递"
application/config/description="2-4人派对合作游戏"
application/run/main_scene="res://scenes/ui/main_menu.tscn"
application/config/use_custom_user_dir=true
application/config/custom_user_dir_name="ChaosDelivery"

; 自动加载
autoload/EventBus="*res://src/autoload/event_bus.gd"
autoload/GameState="*res://src/autoload/game_state.gd"
autoload/NetworkManager="*res://src/autoload/network_manager.gd"
autoload/AudioManager="*res://src/autoload/audio_manager.gd"
autoload/SaveManager="*res://src/autoload/save_manager.gd"
autoload/InputManager="*res://src/autoload/input_manager.gd"

; 渲染
rendering/renderer/rendering_method="forward_plus"
rendering/renderer/rendering_method.mobile="forward_plus"
rendering/environment/defaults/default_clear_color=Color(0.2, 0.2, 0.25, 1)

; 物理
physics/3d/default_gravity=15.0
physics/common/physics_ticks_per_second=60

; 网络
network/limits/packet_peer_stream/max_buffer_po2=20

; 输入
input_devices/pointing/emulate_touch_from_mouse=false

; GDScript
gdscript/warnings/enable_all_warnings=true
gdscript/warnings/treat_warnings_as_errors=false
```

---

## 八、开发检查清单

### 8.1 MVP开发顺序

| 阶段 | 任务 | 预估工时 | 依赖 |
|------|------|----------|------|
| 1 | 项目设置 + 目录结构 | 2h | - |
| 2 | 玩家基础移动 | 4h | 阶段1 |
| 3 | 包裹抓取/放置 | 6h | 阶段2 |
| 4 | 包裹投掷 | 4h | 阶段3 |
| 5 | 订单系统 | 6h | 阶段3 |
| 6 | 基础关卡搭建 | 8h | 阶段4 |
| 7 | 局域网联机 | 12h | 阶段2 |
| 8 | UI框架 | 8h | 阶段5 |
| 9 | 易碎品机制 | 4h | 阶段4 |
| 10 | 整合测试 | 8h | 全部 |

**MVP总预估：62小时**

### 8.2 代码规范

```gdscript
# 命名规范
const MAX_PLAYERS: int = 4          # 常量：SCREAMING_SNAKE_CASE
var player_speed: float = 4.5       # 变量：snake_case
func calculate_velocity() -> void:   # 函数：snake_case
class_name PlayerData               # 类名：PascalCase
enum GamePhase { ... }              # 枚举：PascalCase

# 类型安全
var health: float = 100.0           # 显式类型
var enemies: Array[Enemy] = []      # 类型化数组
@onready var sprite: Sprite2D = $Sprite  # 显式类型

# 信号命名
signal health_changed(new_health: float)  # snake_case
signal player_died                        # 过去式表示事件已发生

# 文档注释
## 对包裹造成伤害。如果包裹易碎且冲击力过大，会破碎。
## [param damage]: 伤害值
## [param impact_velocity]: 冲击速度
func apply_damage(damage: float, impact_velocity: Vector3) -> void:
```

---

## 九、变更日志

| 版本 | 日期 | 变更内容 |
|------|------|----------|
| v0.1 | 2026-03-20 | 初始文档创建，包含架构设计、核心系统、组件设计、实体设计、数据资源、输入映射、项目设置 |

---

*文档状态：初稿 | 下次更新：MVP开发启动后*
