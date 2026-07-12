-- ==========================================
-- 1. ИМПОРТ БИБЛИОТЕКИ И ИНИЦИАЛИЗАЦИЯ
-- ==========================================
local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/hm5650/DummyUi/refs/heads/main/DummyUI.lua"))()

-- Установка темы (по умолчанию Amethyst, можно менять на Dark)
Library:setTheme("Amethyst")

local Window = Library:Window({
    Title = "Bot Controller UI",
    Desc = "Управление ботами",
    Icon = "", -- Пустая строка для иконки согласно ТЗ
    Theme = "Amethyst",
    Config = {
        Keybind = Enum.KeyCode.RightShift,
        Size = UDim2.new(0, 530, 0, 400)
    }
})

-- ==========================================
-- 2. ПЕРЕМЕННЫЕ И СЛУЖЕБНЫЕ СЕРВИСЫ
-- ==========================================
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local LocalPlayer = Players.LocalPlayer
local OWNER_NAME = "OwnerName" -- Ник по умолчанию

local currentTask = nil
local orbitRadius = 10
local orbitSpeed = 2
local followDistance = 5

math.randomseed(os.time())

-- Функция остановки активных циклов
local function stopCurrentTask()
    if currentTask then
        currentTask:Disconnect()
        currentTask = nil
    end
end

-- ==========================================
-- 3. ЛОГИКА БОТА (ORBIT, FOLLOW, JUMP)
-- ==========================================

local function startOrbit(radius, speed)
    stopCurrentTask()
    
    local owner = Players:FindFirstChild(OWNER_NAME)
    if not owner or not owner.Character then return end
    
    local randomDelay = math.random(0, 150) / 100
    local randomAngleOffset = math.random() * math.pi * 2
    local angle = 0
    local botIndex = 1
    local allPlayers = Players:GetPlayers()
    
    for i, player in ipairs(allPlayers) do
        if player == LocalPlayer then botIndex = i break end
    end
    
    task.wait(randomDelay)
    
    currentTask = RunService.RenderStepped:Connect(function(dt)
        local myChar = LocalPlayer.Character
        local ownerHRP = owner.Character:FindFirstChild("HumanoidRootPart")
        
        if myChar and myChar:FindFirstChild("HumanoidRootPart") and ownerHRP then
            angle = angle + (dt * (speed or 2))
            local offsetAngle = angle + (botIndex * (math.pi * 2 / #allPlayers)) + randomAngleOffset
            
            local x = ownerHRP.Position.X + math.cos(offsetAngle) * (radius or 10)
            local z = ownerHRP.Position.Z + math.sin(offsetAngle) * (radius or 10)
            
            local targetPosition = Vector3.new(x, ownerHRP.Position.Y, z)
            local targetCFrame = CFrame.lookAt(targetPosition, ownerHRP.Position)
            
            local tweenInfo = TweenInfo.new(0.05, Enum.EasingStyle.Linear)
            TweenService:Create(myChar.HumanoidRootPart, tweenInfo, {CFrame = targetCFrame}):Play()
        else
            stopCurrentTask()
        end
    end)
end

local function startFollow(distance)
    stopCurrentTask()
    
    local owner = Players:FindFirstChild(OWNER_NAME)
    if not owner or not owner.Character then return end
    
    local dist = distance or 4
    
    currentTask = RunService.RenderStepped:Connect(function()
        local myChar = LocalPlayer.Character
        local ownerChar = owner.Character
        
        if myChar and myChar:FindFirstChild("Humanoid") and ownerChar and ownerChar:FindFirstChild("HumanoidRootPart") then
            local ownerHRP = ownerChar.HumanoidRootPart
            local myHRP = myChar:FindFirstChild("HumanoidRootPart")
            
            if myHRP then
                local currentDist = (ownerHRP.Position - myHRP.Position).Magnitude
                if currentDist > dist then
                    myChar.Humanoid:MoveTo(ownerHRP.Position)
                end
            end
        else
            stopCurrentTask()
        end
    end)
end

-- ==========================================
-- 4. СОЗДАНИЕ СТРАНИЦ И НАПОЛНЕНИЕ ЭЛЕМЕНТАМИ UI
-- ==========================================

local MainPage = Window:Tab({Title = "Главная", Icon = ""})
local SettingsPage = Window:Tab({Title = "Настройки UI", Icon = ""})

--- === ВКЛАДКА "ГЛАВНАЯ" === ---

-- Настройка ника хозяина
MainPage:Textbox({
    Title = "Ник владельца",
    Desc = "Ник игрока, за которым будут следовать боты",
    Placeholder = "OwnerName",
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

-- ==========================================
-- 5. ЗАПУСК ЛОГИКИ СЛУШАТЕЛЕЙ ЧАТА (BACKUP)
-- ==========================================

-- Словесные ARMY-алиасы: "Army, jump" работает так же, как "!jump".
-- Чтобы добавить новый алиас, просто впиши строку вида ["фраза"] = "!команда".
local ARMY_ALIASES = {
    ["jump"] = "!jump",
    ["follow me"] = "!follow",
    ["follow"] = "!follow",
    ["orbit"] = "!orbit",
    ["stop"] = "!stop",
    ["stay"] = "!stop",
    ["halt"] = "!stop",
}

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

local function processCommand(msg)
    local args = string.split(resolveArmyAlias(msg) or msg, " ")
    local command = string.lower(args[1])

    if command == "!jump" then
        local char = LocalPlayer.Character
        if char and char:FindFirstChild("Humanoid") then char.Humanoid.Jump = true end
    elseif command == "!orbit" then
        local r = tonumber(args[2]) or orbitRadius
        local s = tonumber(args[3]) or orbitSpeed
        task.spawn(function() startOrbit(r, s) end)
    elseif command == "!follow" then
        local d = tonumber(args[2]) or followDistance
        startFollow(d)
    elseif command == "!stop" then
        stopCurrentTask()
        local char = LocalPlayer.Character
        if char and char:FindFirstChild("Humanoid") then
            char.Humanoid:MoveTo(char.HumanoidRootPart.Position)
        end
    end
end

local function listenPlayer(player)
    player.Chatted:Connect(function(msg)
        if player.Name == OWNER_NAME then
            processCommand(msg)
        end
    end)
end

Players.PlayerAdded:Connect(listenPlayer)
for _, p in ipairs(Players:GetPlayers()) do listenPlayer(p) end

local ok, err = pcall(function()
    TextChatService.MessageReceived:Connect(function(textChatMessage)
        if textChatMessage.TextSource then
            local sender = Players:GetPlayerByUserId(textChatMessage.TextSource.UserId)
            if sender and sender.Name == OWNER_NAME then
                processCommand(textChatMessage.Text)
            end
        end
    end)
end)
if not ok then
    warn("[Swarm]: Не удалось подписаться на TextChatService.MessageReceived: " .. tostring(err))
end

print(">>> UI и скрипт управления ботами успешно запущены! <<<")
