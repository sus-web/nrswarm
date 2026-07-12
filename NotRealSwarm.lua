-- ==========================================
-- 0. ВОССТАНОВЛЕНИЕ СОСТОЯНИЯ ПОСЛЕ !panic
-- ==========================================
-- getgenv() — общее окружение исполнителя, которое переживает повторное
-- выполнение скрипта в рамках одной игровой сессии (обычные local-переменные это
-- состояние теряют вместе со старым запуском). Если getgenv недоступен — fallback на _G.
local panicEnv = (typeof(getgenv) == "function" and getgenv()) or _G
local panicState = panicEnv.__SwarmPanicState
panicEnv.__SwarmPanicState = nil

-- Ссылка на самого себя — нужна !panic, чтобы перезагрузить скрипт через HttpGet
local SELF_SCRIPT_URL = "https://raw.githubusercontent.com/sus-web/nrswarm/master/NotRealSwarm.lua"

-- ==========================================
-- 1. ИМПОРТ БИБЛИОТЕКИ И ИНИЦИАЛИЗАЦИЯ
-- ==========================================

-- DummyUI полагается на устаревшую глобальную функцию delay() (для авто-выбора
-- вкладки при загрузке, анимаций тогглов/слайдеров и т.д.). В части исполнителей
-- её больше нет, из-за чего UI открывается пустым — контент вкладки просто
-- никогда не становится видимым. Подставляем свою реализацию поверх task.delay.
if not delay then
    function delay(t, f)
        task.delay(t, f)
    end
end

local libraryOk, Library = pcall(function()
    return loadstring(game:HttpGet("https://raw.githubusercontent.com/hm5650/DummyUi/refs/heads/main/DummyUI.lua"))()
end)

if not libraryOk or not Library then
    warn("[Swarm]: Не удалось загрузить/выполнить DummyUI.lua: " .. tostring(Library))
    return
end

print("[Swarm]: Библиотека DummyUI загружена")

-- Установка темы (по умолчанию Amethyst, можно менять на Dark)
pcall(function() Library:setTheme("Amethyst") end)

local windowOk, Window = pcall(function()
    return Library:Window({
        Title = "Bot Controller UI",
        Desc = "Управление ботами",
        Icon = "", -- Пустая строка для иконки согласно ТЗ
        Theme = "Amethyst",
        Config = {
            Keybind = Enum.KeyCode.RightShift,
            Size = UDim2.new(0, 530, 0, 400)
        },
        CloseUIButton = {
            Enabled = true,
            Text = "Открыть UI"
        }
    })
end)

if not windowOk or not Window then
    warn("[Swarm]: Не удалось создать окно (Library:Window): " .. tostring(Window))
    return
end

print("[Swarm]: Окно UI создано")

-- ==========================================
-- 2. ПЕРЕМЕННЫЕ И СЛУЖЕБНЫЕ СЕРВИСЫ
-- ==========================================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local OWNER_NAME = (panicState and panicState.ownerName) or "" -- Ник владельца задаётся через поле в UI

local currentTask = nil
local orbitRadius = 10
local orbitSpeed = 2
local followDistance = 5

-- Формация вокруг владельца, чтобы боты не толпились в одной точке при follow/swim/orbit
local FORMATION_HEIGHT_LAYERS = 3       -- сколько высотных "этажей" вокруг владельца
local FORMATION_HEIGHT_STEP = 4         -- расстояние по Y между этажами (studs), всегда вверх — чтобы не уйти под пол
local FORMATION_IDLE_SPIN_SPEED = 0.3   -- рад/сек — медленное кружение, пока владелец стоит на месте
local GOLDEN_ANGLE = 2.399963229728653  -- ~137.5°, равномерно "рассыпает" ботов по кругу независимо от их числа
local SWIM_VERTICAL_RATIO = 0.6         -- во сколько раз вертикальная орбита !swim медленнее горизонтальной
local SWIM_VERTICAL_SCALE = 0.5         -- амплитуда вертикального колебания относительно радиуса
local LINEUP_ROW_SIZE = 5               -- сколько ботов в одной шеренге по умолчанию
local LINEUP_SPACING = 4                -- studs между соседними ботами в шеренге
local LINEUP_ROW_GAP = 5                -- studs между шеренгами

-- Состояние master/node-протокола (см. секцию 5) — переживает !panic через panicState
local NETWORK_SECRET = (panicState and panicState.networkSecret) or ""
local isMasterNode = (panicState and panicState.isMasterNode) or false
local masterNodeName = panicState and panicState.masterNodeName or nil
local nodeRoster = (panicState and panicState.nodeRoster) or {} -- (только у мастер-ноды) имена нод, подтвердивших связь

math.randomseed(os.time())

-- "Полёт" для !orbit/!swim через BodyVelocity/BodyGyro (НЕ Anchored+CFrame).
-- Anchored отключает физическую симуляцию, а вместе с ней и сетевую репликацию
-- позиции — из-за этого полёт был виден только на своём клиенте, а после !stop
-- сервер "досчитывал" реальную позицию и персонажа резко дёргало на глазах у всех,
-- и это было не остановить чисто. BodyVelocity/BodyGyro прикладывают силу к обычной
-- (не заякоренной) части — она продолжает реплицироваться как при обычной ходьбе,
-- а гравитация не мешает, потому что сила BodyVelocity её просто перевешивает.
local FLY_MAX_FORCE = Vector3.new(1e6, 1e6, 1e6)
local FLY_MAX_TORQUE = Vector3.new(1e6, 1e6, 1e6)
local FLY_SPEED = 40 -- studs/сек, максимальная скорость полёта

local flyModeCharacter = nil
local flyModeOriginalCollide = {}
local flyBodyVelocity = nil
local flyBodyGyro = nil

local function disableFlyMode()
    if not flyModeCharacter then return end

    for part, wasCollidable in pairs(flyModeOriginalCollide) do
        if part and part.Parent then part.CanCollide = wasCollidable end
    end
    flyModeOriginalCollide = {}

    if flyBodyVelocity then flyBodyVelocity:Destroy() flyBodyVelocity = nil end
    if flyBodyGyro then flyBodyGyro:Destroy() flyBodyGyro = nil end

    local hum = flyModeCharacter:FindFirstChild("Humanoid")
    if hum then hum:ChangeState(Enum.HumanoidStateType.GettingUp) end

    flyModeCharacter = nil
end

local function enableFlyMode(character)
    if flyModeCharacter == character then return end
    disableFlyMode() -- на случай, если "летал" другой персонаж (например, после респавна)

    local hrp = character and character:FindFirstChild("HumanoidRootPart")
    local hum = character and character:FindFirstChild("Humanoid")
    if not hrp or not hum then return end

    hum:ChangeState(Enum.HumanoidStateType.Physics)

    flyModeOriginalCollide = {}
    for _, part in ipairs(character:GetDescendants()) do
        if part:IsA("BasePart") then
            flyModeOriginalCollide[part] = part.CanCollide
            part.CanCollide = false
        end
    end

    flyBodyVelocity = Instance.new("BodyVelocity")
    flyBodyVelocity.MaxForce = FLY_MAX_FORCE
    flyBodyVelocity.Velocity = Vector3.new()
    flyBodyVelocity.Parent = hrp

    flyBodyGyro = Instance.new("BodyGyro")
    flyBodyGyro.MaxTorque = FLY_MAX_TORQUE
    flyBodyGyro.CFrame = hrp.CFrame
    flyBodyGyro.Parent = hrp

    flyModeCharacter = character
end

-- Двигает "летящего" персонажа к targetPosition, разворачивая его в сторону lookAtPosition
local function flyTo(hrp, targetPosition, lookAtPosition)
    if not flyBodyVelocity or not flyBodyGyro then return end
    local toTarget = targetPosition - hrp.Position
    local dist = toTarget.Magnitude
    flyBodyVelocity.Velocity = dist > 0.05 and (toTarget.Unit * math.min(dist * 4, FLY_SPEED)) or Vector3.new()
    flyBodyGyro.CFrame = CFrame.lookAt(hrp.Position, lookAtPosition)
end

-- Функция остановки активных циклов
local function stopCurrentTask()
    if currentTask then
        currentTask:Disconnect()
        currentTask = nil
    end
    disableFlyMode()
end

-- Индекс текущего бота среди всех игроков сервера (нужен, чтобы разносить ботов в пространстве)
local function getBotIndex()
    local botIndex = 1
    for i, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer then botIndex = i break end
    end
    return botIndex
end

-- Смещение от владельца для конкретного бота: по кругу (golden angle) и по высоте (этажи).
-- Высота всегда >= 0, поэтому бот никогда не уходит под пол.
local function getFormationOffset(botIndex, angle, radius)
    local heightLayer = botIndex % FORMATION_HEIGHT_LAYERS
    local x = math.cos(angle) * radius
    local z = math.sin(angle) * radius
    local y = heightLayer * FORMATION_HEIGHT_STEP
    return Vector3.new(x, y, z)
end

-- Отправка личного сообщения ("/w Имя текст") прямо из скрипта, без ручного набора.
-- Пробуем оба чат-протокола Roblox (современный TextChatService и легаси-ремоут),
-- т.к. в разных играх включены разные версии чата — что не сработает, то просто
-- тихо промахнётся мимо pcall.
local function sendWhisper(targetName, message)
    pcall(function()
        local generalChannel = TextChatService.TextChannels:FindFirstChild("RBXGeneral")
        if generalChannel then
            generalChannel:SendAsync("/w " .. targetName .. " " .. message)
        end
    end)

    pcall(function()
        local chatEvents = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
        local sayEvent = chatEvents and chatEvents:FindFirstChild("SayMessageRequest")
        if sayEvent then
            sayEvent:FireServer("/w " .. targetName .. " " .. message, "All")
        end
    end)
end

-- Делает ЭТОТ аккаунт мастер-нодой и представляется всем остальным игрокам по
-- очереди через ЛС. Вызывается и с клиента владельца (после ASSIGN по сети), и
-- напрямую с самого бота (кнопка "Сделать эту ноду мастер-нодой" в UI) — разницы
-- нет, в обоих случаях реальная защита — это совпадение NETWORK_SECRET у нод,
-- которые впоследствии примут наш HELLO.
local function becomeMasterNode()
    isMasterNode = true
    masterNodeName = LocalPlayer.Name
    nodeRoster = {}
    print("[Swarm]: Эта нода теперь MASTER NODE")

    task.spawn(function()
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer then
                sendWhisper(player.Name, table.concat({"##SWARM##", "HELLO", NETWORK_SECRET, OWNER_NAME, LocalPlayer.Name}, " "))
                task.wait(0.5) -- представляемся по очереди, не спамим всех разом
            end
        end
    end)
end

-- Все RBXScriptConnection, созданные этим скриптом — нужно для !panic, чтобы
-- полностью "отгрузить" старый экземпляр перед перезагрузкой (иначе старые
-- подключения продолжат висеть в памяти и дублировать обработку команд).
local activeConnections = {}

local function track(connection)
    table.insert(activeConnections, connection)
    return connection
end

local function disconnectAll()
    for _, connection in ipairs(activeConnections) do
        pcall(function() connection:Disconnect() end)
    end
    activeConnections = {}
end

-- Закрывает текущее окно DummyUI перед !panic-перезагрузкой, чтобы не плодить
-- дубликаты UI поверх друг друга. "Dummy Kawaii" — реальное имя ScreenGui библиотеки.
local function destroyExistingUI()
    pcall(function()
        local coreGui = game:GetService("CoreGui")
        local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
        for _, container in ipairs({coreGui, playerGui}) do
            if container then
                local gui = container:FindFirstChild("Dummy Kawaii")
                if gui then gui:Destroy() end
            end
        end
    end)
end

-- ==========================================
-- 3. ЛОГИКА БОТА (ORBIT, FOLLOW/SWIM, LINEUP, JUMP, RESET)
-- ==========================================

local function startOrbit(radius, speed)
    stopCurrentTask()

    local owner = Players:FindFirstChild(OWNER_NAME)
    if not owner or not owner.Character then return end

    local myChar = LocalPlayer.Character
    if not myChar then return end

    enableFlyMode(myChar) -- без этого персонажа в воздухе трясёт и цепляет за объекты

    local randomDelay = math.random(0, 150) / 100
    local randomAngleOffset = math.random() * math.pi * 2
    local angle = 0
    local botIndex = getBotIndex()
    local allPlayers = Players:GetPlayers()
    local heightOffset = (botIndex % FORMATION_HEIGHT_LAYERS) * FORMATION_HEIGHT_STEP

    task.wait(randomDelay)

    currentTask = RunService.RenderStepped:Connect(function(dt)
        local hrp = myChar:FindFirstChild("HumanoidRootPart")
        local ownerHRP = owner.Character and owner.Character:FindFirstChild("HumanoidRootPart")

        if hrp and ownerHRP then
            angle = angle + (dt * (speed or 2))
            local offsetAngle = angle + (botIndex * (math.pi * 2 / #allPlayers)) + randomAngleOffset

            local x = ownerHRP.Position.X + math.cos(offsetAngle) * (radius or 10)
            local z = ownerHRP.Position.Z + math.sin(offsetAngle) * (radius or 10)

            local targetPosition = Vector3.new(x, ownerHRP.Position.Y + heightOffset, z)
            flyTo(hrp, targetPosition, ownerHRP.Position)
        else
            stopCurrentTask()
        end
    end)
end

-- !follow: обычная ходьба (без полёта) — Humanoid:MoveTo по земле. Каждый бот
-- держит свой слот в формации вокруг владельца (golden angle + высотный этаж),
-- чтобы не толпиться в одной точке. Если владелец стоит на месте — слот медленно
-- вращается вокруг него (это и есть "крутиться по орбите на месте").
local function startFollow(radius)
    stopCurrentTask()

    local owner = Players:FindFirstChild(OWNER_NAME)
    if not owner or not owner.Character then return end

    local botIndex = getBotIndex()
    local angle = botIndex * GOLDEN_ANGLE
    local dist = radius or 4
    local lastOwnerPos = nil

    currentTask = RunService.RenderStepped:Connect(function(dt)
        local myChar = LocalPlayer.Character
        local ownerChar = owner.Character

        if myChar and myChar:FindFirstChild("Humanoid") and ownerChar and ownerChar:FindFirstChild("HumanoidRootPart") then
            local ownerHRP = ownerChar.HumanoidRootPart
            local myHRP = myChar:FindFirstChild("HumanoidRootPart")

            local ownerIsMoving = lastOwnerPos and (ownerHRP.Position - lastOwnerPos).Magnitude > 0.05
            if not ownerIsMoving then
                angle = angle + dt * FORMATION_IDLE_SPIN_SPEED
            end
            lastOwnerPos = ownerHRP.Position

            if myHRP then
                local targetPos = ownerHRP.Position + getFormationOffset(botIndex, angle, dist)
                local currentDist = (targetPos - myHRP.Position).Magnitude
                if currentDist > 2 then
                    myChar.Humanoid:MoveTo(targetPos)
                end
            end
        else
            stopCurrentTask()
        end
    end)
end

-- !swim: включает полёт (BodyVelocity/BodyGyro, как в !orbit) и принудительно
-- держит анимацию плавания через Humanoid:ChangeState(Swimming) — так персонаж
-- плывёт прямо по воздуху, а не только в настоящей воде. Пока владелец стоит на
-- месте, бот медленно облетает его по полноценной 3D-орбите (горизонталь + вертикаль).
local function startSwim(radius)
    stopCurrentTask()

    local owner = Players:FindFirstChild(OWNER_NAME)
    if not owner or not owner.Character then return end

    local myChar = LocalPlayer.Character
    if not myChar then return end

    enableFlyMode(myChar)

    local botIndex = getBotIndex()
    local angle = botIndex * GOLDEN_ANGLE
    local dist = radius or 4
    local lastOwnerPos = nil

    currentTask = RunService.RenderStepped:Connect(function(dt)
        local hrp = myChar:FindFirstChild("HumanoidRootPart")
        local hum = myChar:FindFirstChild("Humanoid")
        local ownerChar = owner.Character
        local ownerHRP = ownerChar and ownerChar:FindFirstChild("HumanoidRootPart")

        if hrp and hum and ownerHRP then
            hum:ChangeState(Enum.HumanoidStateType.Swimming)

            local ownerIsMoving = lastOwnerPos and (ownerHRP.Position - lastOwnerPos).Magnitude > 0.05
            if not ownerIsMoving then
                angle = angle + dt * FORMATION_IDLE_SPIN_SPEED
            end
            lastOwnerPos = ownerHRP.Position

            local x = math.cos(angle) * dist
            local z = math.sin(angle) * dist
            local y = math.sin(angle * SWIM_VERTICAL_RATIO) * dist * SWIM_VERTICAL_SCALE
            local targetPosition = ownerHRP.Position + Vector3.new(x, y, z)
            flyTo(hrp, targetPosition, ownerHRP.Position)
        else
            stopCurrentTask()
        end
    end)
end

-- Общее перемещение в конкретную ячейку шеренги — row/col уже вычислены (либо
-- локально через сортировку по UserId, либо получены от мастер-ноды по ЛС).
local function moveToLineupSlot(row, col, colsInRow)
    stopCurrentTask()

    local owner = Players:FindFirstChild(OWNER_NAME)
    if not owner or not owner.Character then return end
    local ownerHRP = owner.Character:FindFirstChild("HumanoidRootPart")
    if not ownerHRP then return end

    local anchor = ownerHRP.Position
    local xOffset = (col - (colsInRow - 1) / 2) * LINEUP_SPACING
    local zOffset = (row + 1) * LINEUP_ROW_GAP
    local targetPos = anchor + Vector3.new(xOffset, 0, zOffset)

    currentTask = RunService.RenderStepped:Connect(function()
        local myChar = LocalPlayer.Character
        if myChar and myChar:FindFirstChild("Humanoid") and myChar:FindFirstChild("HumanoidRootPart") then
            local currentDist = (targetPos - myChar.HumanoidRootPart.Position).Magnitude
            if currentDist > 2 then
                myChar.Humanoid:MoveTo(targetPos)
            end
        else
            stopCurrentTask()
        end
    end)
end

-- !lineup БЕЗ мастер-ноды (запасной способ): каждый бот сам сортирует список
-- игроков по UserId (одинаковое число у всех клиентов) и вычисляет свою ячейку.
-- Ограничение: если на сервере есть посторонние игроки — они тоже попадут в
-- подсчёт и собьют нумерацию. Чтобы это исключить, назначьте мастер-ноду (см. ниже).
local function startLineup(rowSize)
    local owner = Players:FindFirstChild(OWNER_NAME)
    if not owner then return end

    local bots = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Name ~= OWNER_NAME then
            table.insert(bots, player)
        end
    end
    table.sort(bots, function(a, b) return a.UserId < b.UserId end)

    local myRank = nil
    for i, player in ipairs(bots) do
        if player == LocalPlayer then myRank = i break end
    end
    if not myRank then return end

    local size = rowSize or LINEUP_ROW_SIZE
    local row = math.floor((myRank - 1) / size)
    local col = (myRank - 1) % size
    local colsInRow = math.min(size, #bots - row * size)

    moveToLineupSlot(row, col, colsInRow)
end

-- !lineup ОТ ИМЕНИ МАСТЕР-НОДЫ: рассылает каждой известной ноде её персональную
-- ячейку по ЛС и сама тоже встаёт в строй. В nodeRoster попадают только игроки,
-- реально приславшие ACK на наш HELLO с верным секретным кодом — то есть только
-- настоящие ноды с этим же скриптом, а не случайные посторонние на сервере.
local function assignLineupSlots(rowSize)
    local size = rowSize or LINEUP_ROW_SIZE
    local nodes = {}
    for name in pairs(nodeRoster) do table.insert(nodes, name) end
    table.sort(nodes)

    local total = #nodes + 1 -- + сама мастер-нода

    local myColsInRow = math.min(size, total)
    moveToLineupSlot(0, 0, myColsInRow)

    for i, name in ipairs(nodes) do
        local rank = i + 1
        local row = math.floor((rank - 1) / size)
        local col = (rank - 1) % size
        local colsInRow = math.min(size, total - row * size)
        sendWhisper(name, table.concat({"##SWARM##", "SLOT", NETWORK_SECRET, tostring(row), tostring(col), tostring(colsInRow)}, " "))
    end
end

-- Непрерывный прыжок до команды !stop
local function startJumping()
    stopCurrentTask()

    currentTask = RunService.Heartbeat:Connect(function()
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChild("Humanoid")
        if hum then
            hum.Jump = true
        else
            stopCurrentTask()
        end
    end)
end

-- ==========================================
-- 4. СОЗДАНИЕ СТРАНИЦ И НАПОЛНЕНИЕ ЭЛЕМЕНТАМИ UI
-- ==========================================

local mainTabOk, MainPage = pcall(function() return Window:Tab({Title = "Главная", Icon = ""}) end)
local settingsTabOk, SettingsPage = pcall(function() return Window:Tab({Title = "Настройки UI", Icon = ""}) end)

if not mainTabOk or not MainPage then
    warn("[Swarm]: Не удалось создать вкладку 'Главная' (Window:Tab): " .. tostring(MainPage))
    return
end
if not settingsTabOk or not SettingsPage then
    warn("[Swarm]: Не удалось создать вкладку 'Настройки UI' (Window:Tab): " .. tostring(SettingsPage))
    return
end

print("[Swarm]: Вкладки созданы, наполняю элементами UI")

--- === ВКЛАДКА "ГЛАВНАЯ" === ---

-- Настройка ника хозяина
MainPage:Textbox({
    Title = "Ник владельца",
    Desc = "Ник игрока, за которым будут следовать боты",
    Placeholder = "Введите ник владельца",
    ClearText = false,
    Callback = function(text)
        pcall(function()
            if text and text ~= "" then
                OWNER_NAME = text
                print("[UI]: Владелец изменен на " .. OWNER_NAME)
            end
        end)
    end
})

-- Кнопка Прыжка
MainPage:Button({
    Title = "Подпрыгнуть (!jump)",
    Desc = "Заставляет бота подпрыгнуть",
    Callback = function()
        pcall(function()
            local char = LocalPlayer.Character
            if char and char:FindFirstChild("Humanoid") then
                char.Humanoid.Jump = true
            end
        end)
    end
})

-- Кнопка Орбиты
MainPage:Button({
    Title = "Запустить Орбиту (!orbit)",
    Desc = "Начать кружение вокруг владельца",
    Callback = function()
        pcall(function()
            task.spawn(function()
                startOrbit(orbitRadius, orbitSpeed)
            end)
        end)
    end
})

-- Кнопка Следования
MainPage:Button({
    Title = "Идти за мной (!follow)",
    Desc = "Бот начинает следовать за хозяином",
    Callback = function()
        pcall(function()
            startFollow(followDistance)
        end)
    end
})

-- Кнопка Стоп
MainPage:Button({
    Title = "Остановить все (!stop)",
    Desc = "Прекращает любые действия бота",
    Callback = function()
        pcall(function()
            stopCurrentTask()
            local char = LocalPlayer.Character
            if char and char:FindFirstChild("Humanoid") then
                char.Humanoid:MoveTo(char.HumanoidRootPart.Position)
            end
        end)
    end
})

--- === ВКЛАДКА "НАСТРОЙКИ UI И ТЕМЫ" === ---

-- Смена темы интерфейса
SettingsPage:Button({
    Title = "Переключить на Темную тему",
    Desc = "Сменить оформление на Dark",
    Callback = function()
        pcall(function()
            Library:setTheme("Dark")
        end)
    end
})

SettingsPage:Button({
    Title = "Переключить на Аметистовую тему",
    Desc = "Сменить оформление на Amethyst",
    Callback = function()
        pcall(function()
            Library:setTheme("Amethyst")
        end)
    end
})

-- Выбор цвета (пример использования ColorPicker из ТЗ)
SettingsPage:ColorPicker({
    Title = "Цвет акцента",
    Desc = "Пример кастомизации цвета через RGB",
    Value = Color3.fromRGB(140, 0, 255),
    Callback = function(r, g, b)
        pcall(function()
            print(string.format("[UI ColorPicker]: R:%d G:%d B:%d", r, g, b))
        end)
    end
})

--- === MASTER NODE (координация !lineup через ЛС, без доверия сортировке по UserId) === ---

-- ВАЖНО: секретный код должен быть введён одинаковым на владельце и на всех
-- ботах — это единственная защита протокола от посторонних игроков на сервере
-- (без него любой, кто угадает формат сообщений, мог бы попытаться выдать себя
-- за мастер-ноду). Это не криптографическая защита, а простая проверка "свой/чужой".
SettingsPage:Textbox({
    Title = "Секретный код сети",
    Desc = "Одинаковый код должен быть на владельце и на всех ботах — иначе протокол master/node не сработает",
    Placeholder = "Придумайте код",
    ClearText = false,
    Callback = function(text)
        pcall(function()
            if text and text ~= "" then
                NETWORK_SECRET = text
            end
        end)
    end
})

local selectedNodeName = nil

local initialPlayerList = {}
for _, player in ipairs(Players:GetPlayers()) do
    if player ~= LocalPlayer then
        table.insert(initialPlayerList, player.Name)
    end
end

local nodeDropdown = SettingsPage:Dropdown({
    Title = "Выбор ноды",
    Desc = "Кого назначить мастер-нодой (нажмите 'Обновить список', если игрок зашёл позже)",
    List = initialPlayerList,
    Multi = false,
    Callback = function(name)
        selectedNodeName = name
    end
})

SettingsPage:Button({
    Title = "Обновить список игроков",
    Desc = "Перечитать текущих игроков на сервере в списке выше",
    Callback = function()
        pcall(function()
            nodeDropdown:Clear()
            for _, player in ipairs(Players:GetPlayers()) do
                if player ~= LocalPlayer then
                    nodeDropdown:Add(player.Name)
                end
            end
        end)
    end
})

SettingsPage:Button({
    Title = "Назначить мастер-нодой",
    Desc = "Выбранный игрок станет мастер-нодой и представится остальным по ЛС",
    Callback = function()
        pcall(function()
            if LocalPlayer.Name ~= OWNER_NAME then
                warn("[Swarm]: Назначать мастер-ноду может только клиент владельца (см. поле 'Ник владельца')")
                return
            end
            if not selectedNodeName or not Players:FindFirstChild(selectedNodeName) then
                warn("[Swarm]: Сначала выберите существующего игрока в списке")
                return
            end
            if NETWORK_SECRET == "" then
                warn("[Swarm]: Сначала задайте секретный код (должен совпадать на всех ботах)")
                return
            end
            sendWhisper(selectedNodeName, table.concat({"##SWARM##", "ASSIGN", NETWORK_SECRET, OWNER_NAME}, " "))
            print("[Swarm]: Отправлено назначение мастер-ноды игроку " .. selectedNodeName)
        end)
    end
})

-- Для случая, когда вы сидите за самим аккаунтом-ботом: не нужно слать себе ЛС
-- через владельца, просто нажмите эту кнопку прямо здесь.
SettingsPage:Button({
    Title = "Сделать эту ноду мастер-нодой",
    Desc = "Назначает МАСТЕРОМ прямо этот аккаунт, без ЛС от владельца",
    Callback = function()
        pcall(function()
            if OWNER_NAME == "" then
                warn("[Swarm]: Сначала укажите 'Ник владельца' — он передаётся в HELLO, по нему остальные ноды проверяют, что мастер настоящий")
                return
            end
            if NETWORK_SECRET == "" then
                warn("[Swarm]: Сначала задайте секретный код (должен совпадать на всех ботах)")
                return
            end
            becomeMasterNode()
        end)
    end
})

SettingsPage:Button({
    Title = "Показать статус мастер-ноды",
    Desc = "Печатает в консоль текущее состояние master/node на этом боте",
    Callback = function()
        pcall(function()
            print(string.format("[Swarm]: isMasterNode=%s masterNodeName=%s", tostring(isMasterNode), tostring(masterNodeName)))
            if isMasterNode then
                local names = {}
                for name in pairs(nodeRoster) do table.insert(names, name) end
                print("[Swarm]: Ростер нод (" .. #names .. "): " .. table.concat(names, ", "))
            end
        end)
    end
})

-- ==========================================
-- 5. ПРОТОКОЛ MASTER/NODE И ЗАПУСК ЛОГИКИ СЛУШАТЕЛЕЙ ЧАТА (BACKUP)
-- ==========================================

-- Словесные ARMY-алиасы: "Army, jump" работает так же, как "!jump".
-- Чтобы добавить новый алиас, просто впиши строку вида ["фраза"] = "!команда".
local ARMY_ALIASES = {
    ["jump"] = "!jump",
    ["jump!"] = "!jumping",
    ["follow me"] = "!follow",
    ["follow"] = "!follow",
    ["swim"] = "!swim",
    ["line up"] = "!lineup",
    ["lineup"] = "!lineup",
    ["orbit"] = "!orbit",
    ["stop"] = "!stop",
    ["stay"] = "!stop",
    ["halt"] = "!stop",
    ["assist"] = "!assist",
    ["die"] = "!reset",
    ["panic"] = "!panic",
}

-- Игроки (ники в нижнем регистре), которым владелец временно выдал доступ к управлению через !assist
local assistants = (panicState and panicState.assistants) or {}

-- Мастер-нода (см. ниже) тоже считается авторизованным отправителем команд —
-- владелец назначает её лично, поэтому она имеет право транслировать команды.
local function isAuthorized(name)
    return name == OWNER_NAME or assistants[string.lower(name)] ~= nil or (masterNodeName ~= nil and name == masterNodeName)
end

-- Превращает "Army, follow me" в "!follow" (с сохранением доп. аргументов после фразы)
local function resolveArmyAlias(msg)
    local phrase = string.lower(msg):match("^army,?%s+(.-)%s*$")
    if not phrase then return nil end

    local bestPhrase, bestCommand = nil, nil
    for aliasPhrase, command in pairs(ARMY_ALIASES) do
        if phrase == aliasPhrase or phrase:sub(1, #aliasPhrase + 1) == aliasPhrase .. " " then
            if not bestPhrase or #aliasPhrase > #bestPhrase then
                bestPhrase, bestCommand = aliasPhrase, command
            end
        end
    end

    if not bestCommand then return nil end
    return bestCommand .. phrase:sub(#bestPhrase + 1)
end

local function isSecretValid(secret)
    return NETWORK_SECRET ~= "" and secret == NETWORK_SECRET
end

-- Служебные сообщения протокола master/node идут с префиксом "##SWARM##" по ЛС,
-- отдельно от обычных !команд. Возвращает true, если сообщение было служебным и
-- уже обработано — тогда его не нужно дальше отдавать в processCommand.
local function processProtocolMessage(msg, senderName)
    if msg:sub(1, 9) ~= "##SWARM##" then return false end

    local parts = string.split(msg, " ")
    local msgType = parts[2]

    if msgType == "ASSIGN" then
        -- Только сам владелец (проверка по имени отправителя) может назначить мастер-ноду по сети
        local secret, owner = parts[3], parts[4]
        if senderName == OWNER_NAME and isSecretValid(secret) and owner == OWNER_NAME then
            becomeMasterNode()
        end
        return true
    end

    if msgType == "HELLO" then
        local secret, owner, master = parts[3], parts[4], parts[5]
        if isSecretValid(secret) and owner == OWNER_NAME and not isMasterNode then
            masterNodeName = master
            print("[Swarm]: Подчиняюсь мастер-ноде " .. tostring(master))
            sendWhisper(master, table.concat({"##SWARM##", "ACK", NETWORK_SECRET, LocalPlayer.Name}, " "))
        end
        return true
    end

    if msgType == "ACK" then
        local secret, nodeName = parts[3], parts[4]
        if isSecretValid(secret) and isMasterNode and nodeName then
            nodeRoster[nodeName] = true
            print("[Swarm]: Нода " .. nodeName .. " подтвердила связь")
        end
        return true
    end

    if msgType == "SLOT" then
        local secret = parts[3]
        local row, col, colsInRow = tonumber(parts[4]), tonumber(parts[5]), tonumber(parts[6])
        if isSecretValid(secret) and senderName == masterNodeName and row and col and colsInRow then
            moveToLineupSlot(row, col, colsInRow)
        end
        return true
    end

    return true -- нераспознанный ##SWARM## тип — просто проглатываем, чтобы не улетело в processCommand
end

local function processCommand(msg, senderName)
    local args = string.split(resolveArmyAlias(msg) or msg, " ")
    local command = string.lower(args[1])

    if command == "!assist" then
        -- Выдавать/забирать доступ может только владелец, а не уже допущенные ассистенты
        if senderName ~= OWNER_NAME then return end
        local target = args[2]
        if not target then return end

        if string.lower(target) == "stop" then
            assistants = {}
            print("[Swarm]: Доступ ассистентов отозван у всех")
        else
            assistants[string.lower(target)] = true
            print("[Swarm]: " .. target .. " теперь может управлять ботом")
        end
        return
    end

    if command == "!jump" then
        local char = LocalPlayer.Character
        if char and char:FindFirstChild("Humanoid") then char.Humanoid.Jump = true end
    elseif command == "!jumping" then
        startJumping()
    elseif command == "!orbit" then
        local r = tonumber(args[2]) or orbitRadius
        local s = tonumber(args[3]) or orbitSpeed
        task.spawn(function() startOrbit(r, s) end)
    elseif command == "!follow" then
        local d = tonumber(args[2]) or followDistance
        startFollow(d)
    elseif command == "!swim" then
        local d = tonumber(args[2]) or followDistance
        startSwim(d)
    elseif command == "!lineup" then
        local size = tonumber(args[2]) or LINEUP_ROW_SIZE
        if isMasterNode then
            -- Мастер сам считает слоты по своему ростеру (только реально подтвердившие связь ноды) и рассылает их по ЛС
            assignLineupSlots(size)
        elseif not masterNodeName then
            -- Мастер-нода не назначена — запасной способ через сортировку по UserId
            startLineup(size)
        end
        -- Если мастер назначен, но это не мы — ничего не делаем сами, ждём персональный SLOT от мастера
    elseif command == "!stop" then
        stopCurrentTask()
        local char = LocalPlayer.Character
        if char and char:FindFirstChild("Humanoid") then
            char.Humanoid:MoveTo(char.HumanoidRootPart.Position)
        end
    elseif command == "!reset" then
        stopCurrentTask()
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChild("Humanoid")
        if hum then
            hum.Health = 0
        end
    elseif command == "!panic" then
        print("[Swarm]: !panic — сохраняю состояние и перезагружаю скрипт")
        stopCurrentTask()
        disconnectAll()

        panicEnv.__SwarmPanicState = {
            ownerName = OWNER_NAME,
            assistants = assistants,
            networkSecret = NETWORK_SECRET,
            isMasterNode = isMasterNode,
            masterNodeName = masterNodeName,
            nodeRoster = nodeRoster,
        }

        destroyExistingUI()

        task.spawn(function()
            task.wait(0.2)
            local reloadOk, reloadErr = pcall(function()
                loadstring(game:HttpGet(SELF_SCRIPT_URL))()
            end)
            if not reloadOk then
                warn("[Swarm]: !panic — не удалось перезагрузить скрипт: " .. tostring(reloadErr))
            end
        end)
    end
end

-- Общая точка входа для входящих сообщений: сперва проверяем протокол master/node
-- (он валиден для ЛЮБОГО отправителя — доверие там основано на секретном коде, а
-- не на isAuthorized), и только если это не протокольное сообщение — проверяем
-- обычные права доступа и передаём в processCommand.
local function handleIncomingMessage(msg, senderName)
    if processProtocolMessage(msg, senderName) then return end
    if isAuthorized(senderName) then
        processCommand(msg, senderName)
    end
end

local function listenPlayer(player)
    track(player.Chatted:Connect(function(msg)
        handleIncomingMessage(msg, player.Name)
    end))
end

track(Players.PlayerAdded:Connect(listenPlayer))
for _, p in ipairs(Players:GetPlayers()) do listenPlayer(p) end

local ok, err = pcall(function()
    track(TextChatService.MessageReceived:Connect(function(textChatMessage)
        if textChatMessage.TextSource then
            local sender = Players:GetPlayerByUserId(textChatMessage.TextSource.UserId)
            if sender then
                handleIncomingMessage(textChatMessage.Text, sender.Name)
            end
        end
    end))
end)
if not ok then
    warn("[Swarm]: Не удалось подписаться на TextChatService.MessageReceived: " .. tostring(err))
end

print(">>> UI и скрипт управления ботами успешно запущены! <<<")
