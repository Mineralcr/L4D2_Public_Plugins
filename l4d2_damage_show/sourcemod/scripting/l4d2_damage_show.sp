#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <clientprefs>
/*
ver1.3-----------------------------------------
    1.新增伤害累加显示功能,单个生物累计显示伤害
ver1.2-----------------------------------------
    1.新增霰弹枪伤害合并处理功能
    2.新增数字偏移调整功能
    3.新增字体透明度、伤害显示距离上限限制功能
    4.优化字体显示逻辑，平均每个数字少消耗1个TE
    5.修复致命一击时伤害数值不对的问题
    6.修复tank死亡时显示5000伤害问题
    7.修复火焰伤害数值不对的问题
    8.修复榴弹造成伤害时，伤害位置显示不对的问题
*/
#define PLUGIN_VERSION  "1.3"
#define SPRITE_MATERIAL "materials/sprites/laserbeam.vmt"
#define DMG_HEADSHOT    1 << 30
#define L4D2_MAXPLAYERS 32
#define ZC_BOOMER       2
#define ZC_CHARGER      6
#define ZC_TANK         8
#define UPDATE_INTERVAL 0.1    // 累加模式下，帧更新间隔时间,不要低于0.05，不然游戏会近似认为是0，发送的TE永远存在

enum struct PlayerSetData
{
    int   wpn_id;
    int   wpn_type;
    bool  plugin_switch;
    bool  show_other;
    float last_set_time;
}

enum struct ReturnTwoFloat
{
    float startPt[3];
    float endPt[3];
}

enum struct ShotgunDamageData
{
    int   victim;
    int   attacker;
    int   totalDamage;
    float damagePosition[3];
    int   damageType;
    int   weapon;
    bool  isHeadshot;
    bool  isCreated;
}

enum struct SumShowMode
{
    bool  needShow;
    int   totalDamage;
    int   damageType;
    int   weapon;
    bool  isHeadshot;
    float damagePosition[3];
    float lastShowTime;
    float lastHitTime;
}

enum struct DamageTrans
{
    bool forceHeadshot;
    int  damage;
}

PlayerSetData
    PlayerDataArray[L4D2_MAXPLAYERS + 1];

ShotgunDamageData
    g_ShotgunDamageBuffer[L4D2_MAXPLAYERS + 1][L4D2_MAXPLAYERS + 1];    // [attacker][victim]

SumShowMode
    g_SumShowMode[L4D2_MAXPLAYERS + 1][L4D2_MAXPLAYERS + 1];

DamageTrans
    g_iAttackDamage[L4D2_MAXPLAYERS + 1][L4D2_MAXPLAYERS + 1];

ConVar
    g_hcvar_maxtempentities,
    g_hcvar_plugin_mode,
    g_hcvar_size,
    g_hcvar_gap,
    g_hcvar_alpha,
    g_hcvar_shotgun_merge,
    g_hcvar_x_offset,
    g_hcvar_y_offset,
    g_hcvar_show_distance,
    g_hcvar_mode_add;

bool
    g_bNeverFire[L4D2_MAXPLAYERS + 1];

int
    g_sprite,
    g_iMode,
    g_iAlpha,
    g_iShotgunMerge,
    g_iadd,
    g_iVitcimHealth[L4D2_MAXPLAYERS + 1][L4D2_MAXPLAYERS + 1];
float
    g_fsize,
    g_fgap,
    g_f_x_offset,
    g_f_y_offset,
    g_f_show_distance,
    g_fTankIncap[L4D2_MAXPLAYERS + 1];

Cookie
                 g_cPlayerSettings;

static const int color[][] = {
    {0,    255, 0  }, // 绿色
    { 255, 255, 0  }, // 黄色
    { 255, 255, 255}, // 白色
    { 0,   255, 255}, // 蓝色
    { 255, 0,   0  }  // 红色
};

public Plugin myinfo =
{
    name        = "[L4D2] 爆分系统",
    author      = "洛琪",
    description = "伤害显示",
    version     = PLUGIN_VERSION,
    url         = "https://steamcommunity.com/profiles/76561198812009299/"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    EngineVersion test = GetEngineVersion();
    if (test != Engine_Left4Dead2)
    {
        strcopy(error, err_max, "插件只支持求生之路2");
        return APLRes_SilentFailure;
    }
    return APLRes_Success;
}

public void OnPluginStart()
{
    g_hcvar_maxtempentities = FindConVar("sv_multiplayer_maxtempentities");
    g_hcvar_plugin_mode     = CreateConVar("cf_hint_mode", "3", "显示哪些伤害? 0不显示，1显示对特感伤害,2显示队友友伤，3全部显示", FCVAR_NONE);
    g_hcvar_size            = CreateConVar("cf_hint_size", "5.0", "字体大小", FCVAR_NONE, true, 0.0, true, 100.0);
    g_hcvar_gap             = CreateConVar("cf_hint_gap", "5.0", "字体间隔", FCVAR_NONE, true, 0.0, true, 100.0);
    g_hcvar_alpha           = CreateConVar("cf_hint_alpha", "70", "伤害数字透明度 (0-255, 0完全透明, 255完全不透明)", FCVAR_NONE, true, 0.0, true, 255.0);
    g_hcvar_shotgun_merge   = CreateConVar("cf_hint_shotgun_merge", "1", "散弹枪伤害合并开关 0禁用合并 1启用合并", FCVAR_NONE, true, 0.0, true, 1.0);
    g_hcvar_x_offset        = CreateConVar("cf_hint_x_offset", "20.0", "伤害显示位置基于受伤点的x偏移距离", FCVAR_NONE, true, -100.0, true, 100.0);
    g_hcvar_y_offset        = CreateConVar("cf_hint_y_offset", "10.0", "伤害显示位置基于受伤点的y偏移距离", FCVAR_NONE, true, -100.0, true, 100.0);
    g_hcvar_show_distance   = CreateConVar("cf_hint_show_distance", "1500.0", "超过多远距离后不显示伤害数字?开镜状态下例外", FCVAR_NONE, true, 0.0, true, 8192.0);
    g_hcvar_mode_add        = CreateConVar("cf_hint_mode_add", "1", "是否开启伤害累加显示模式?0关闭1开启[此选项可能对性能带宽消耗较大]", FCVAR_NONE, true, 0.0, true, 1.0);
    g_hcvar_plugin_mode.AddChangeHook(ConVarChanged);
    g_hcvar_size.AddChangeHook(ConVarChanged);
    g_hcvar_gap.AddChangeHook(ConVarChanged);
    g_hcvar_alpha.AddChangeHook(ConVarChanged);
    g_hcvar_shotgun_merge.AddChangeHook(ConVarChanged);
    g_hcvar_x_offset.AddChangeHook(ConVarChanged);
    g_hcvar_y_offset.AddChangeHook(ConVarChanged);
    g_hcvar_show_distance.AddChangeHook(ConVarChanged);
    g_hcvar_mode_add.AddChangeHook(ConVarChanged);

    g_cPlayerSettings = new Cookie("l4d_damage_show_set", "damage show settings", CookieAccess_Protected);
    AutoExecConfig(true, "l4d2_damage_show");
    HookEvent("player_left_safe_area", Event_LeftSafeArea, EventHookMode_PostNoCopy);
    HookEvent("player_hurt", Event_PlayerHurt);
    InItVarNum();
}

public void OnConfigsExecuted()
{
    GetCvars();
}

public void ConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    GetCvars();
}

void GetCvars()
{
    g_iMode           = g_hcvar_plugin_mode.IntValue;
    g_fsize           = g_hcvar_size.FloatValue;
    g_fgap            = g_hcvar_gap.FloatValue;
    g_iAlpha          = g_hcvar_alpha.IntValue;
    g_iShotgunMerge   = g_hcvar_shotgun_merge.IntValue;
    g_iadd            = g_hcvar_mode_add.IntValue;
    g_f_x_offset      = g_hcvar_x_offset.FloatValue;
    g_f_y_offset      = g_hcvar_y_offset.FloatValue;
    g_f_show_distance = g_hcvar_show_distance.FloatValue;
}

public void OnMapStart()
{
    g_sprite = PrecacheModel(SPRITE_MATERIAL, true);
}

void InItVarNum()
{
    for (int i = 0; i <= L4D2_MAXPLAYERS; i++)
    {
        PlayerDataArray[i].wpn_id        = -1;
        PlayerDataArray[i].wpn_type      = -1;
        PlayerDataArray[i].plugin_switch = true;
        PlayerDataArray[i].show_other    = false;
        PlayerDataArray[i].last_set_time = 0.0;
        g_fTankIncap[i]                  = 0.0;
        g_bNeverFire[i]                  = true;

        for (int j = 0; j <= L4D2_MAXPLAYERS; j++)
        {
            g_ShotgunDamageBuffer[i][j].victim      = 0;
            g_ShotgunDamageBuffer[i][j].attacker    = 0;
            g_ShotgunDamageBuffer[i][j].totalDamage = 0;
            g_ShotgunDamageBuffer[i][j].isHeadshot  = false;
            g_ShotgunDamageBuffer[i][j].isCreated   = false;
            g_SumShowMode[i][j].needShow            = false;
            g_SumShowMode[i][j].totalDamage         = 0;
            g_SumShowMode[i][j].lastShowTime        = 0.0;
            g_iVitcimHealth[i][j]                   = 0;
        }
    }
    g_hcvar_maxtempentities.SetInt(512);
}

void Event_LeftSafeArea(Event event, const char[] name, bool dontBroadcast)
{
    PrintToChatAll("\x04[伤害显示]:\x05同时按下Tab键+R键可切换伤害显示模式.");
}

public void OnClientCookiesCached(int client)
{
    if (IsFakeClient(client))
        return;

    char cookie[2];
    g_cPlayerSettings.Get(client, cookie, sizeof(cookie));

    if (cookie[0] != 0)
    {
        int c_var = StringToInt(cookie);
        switch (c_var)
        {
            case 1:
            {
                PlayerDataArray[client].plugin_switch = false;
                PlayerDataArray[client].show_other    = false;
            }
            case 2:
            {
                PlayerDataArray[client].plugin_switch = true;
                PlayerDataArray[client].show_other    = false;
            }
            case 3:
            {
                PlayerDataArray[client].plugin_switch = true;
                PlayerDataArray[client].show_other    = true;
            }
        }
    }
}

public void OnPlayerRunCmdPost(int client, int buttons)
{
    if (buttons & IN_SCORE && buttons & IN_RELOAD && PlayerDataArray[client].last_set_time + 1.0 < GetGameTime())
    {
        PlayerDataArray[client].last_set_time = GetGameTime();
        if (!PlayerDataArray[client].plugin_switch)
        {
            PlayerDataArray[client].plugin_switch = true;
            PlayerDataArray[client].show_other    = false;
            PrintToChat(client, "\x04[伤害显示]\x05当前模式:伤害显示开、他人显示关.");
            g_cPlayerSettings.Set(client, "2");
        }
        else
        {
            if (!PlayerDataArray[client].show_other)
            {
                PlayerDataArray[client].show_other = true;
                PrintToChat(client, "\x04[伤害显示]\x05当前模式:伤害显示开、他人显示开.");
                g_cPlayerSettings.Set(client, "3");
            }
            else
            {
                PlayerDataArray[client].plugin_switch = false;
                PlayerDataArray[client].show_other    = false;
                PrintToChat(client, "\x04[伤害显示]\x05当前模式:伤害显示关.");
                g_cPlayerSettings.Set(client, "1");
            }
        }
    }
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_OnTakeDamagePost, SDK_OnTakeDamagePost);
}

// 伤害以事件为准，但是其他参数还是得post里拿容易 另外Post在事件之后触发
void Event_PlayerHurt(Event hEvent, const char[] name, bool dontBroadcast)
{
    if (g_iMode == 0)
        return;

    int attacker = GetClientOfUserId(hEvent.GetInt("attacker"));
    int victim   = GetClientOfUserId(hEvent.GetInt("userid"));
    if (IsValidClient(victim) && IsValidClient(attacker) && GetClientTeam(attacker) == 2 && !IsFakeClient(attacker))
    {
        if (!PlayerDataArray[attacker].plugin_switch)
            return;

        if (g_iMode == 3 || g_iMode & (1 << 0) && GetClientTeam(victim) == 3 || g_iMode & (1 << 1) && GetClientTeam(victim) == 2)
        {
            int  remain_health   = hEvent.GetInt("health");
            int  damage          = hEvent.GetInt("dmg_health");
            bool b_forceHeadshot = false;
            if (remain_health > 1)
            {
                g_iVitcimHealth[attacker][victim] = remain_health;
            }
            else
            {
                if (g_iVitcimHealth[attacker][victim] == 0)
                    damage = GetEntProp(victim, Prop_Data, "m_iMaxHealth");
                else
                    damage = g_iVitcimHealth[attacker][victim];
                g_iVitcimHealth[attacker][victim] = 0;
                b_forceHeadshot                   = true;
            }
            g_iAttackDamage[attacker][victim].damage        = damage;
            g_iAttackDamage[attacker][victim].forceHeadshot = b_forceHeadshot;
        }
    }
}

void SDK_OnTakeDamagePost(int victim, int attacker, int inflictor, float damage, int damagetype, int weapon, const float damageForce[3], const float damagePosition[3])
{
    if (g_iMode == 0)
        return;

    if (IsValidClient(victim) && IsValidClient(attacker) && GetClientTeam(attacker) == 2 && !IsFakeClient(attacker))
    {
        if (!PlayerDataArray[attacker].plugin_switch)
            return;

        if (g_iMode == 3 || g_iMode & (1 << 0) && GetClientTeam(victim) == 3 || g_iMode & (1 << 1) && GetClientTeam(victim) == 2)
        {
            int wpn = weapon == -1 ? inflictor : weapon;
            if (g_iShotgunMerge == 1 && damagetype & DMG_BUCKSHOT)
                HandleShotgunDamage(victim, attacker, wpn, g_iAttackDamage[attacker][victim].damage, damagetype,
                                    damagePosition, g_iAttackDamage[attacker][victim].forceHeadshot);
            else
                DisplayDamage(victim, attacker, wpn, g_iAttackDamage[attacker][victim].damage, damagetype,
                              damagePosition, g_iAttackDamage[attacker][victim].forceHeadshot);
            g_iAttackDamage[attacker][victim].damage        = 0;
            g_iAttackDamage[attacker][victim].forceHeadshot = false;
        }
    }
}

int PrintDigitsInOrder(int number)
{
    if (number < 0)
        return 0;

    int digitCount = 0;
    int temp       = number;
    while (temp != 0)
    {
        digitCount++;
        temp /= 10;
    }
    return digitCount;
}

// x y 平面内偏移 z 法线方向偏移
ReturnTwoFloat CalculatePoint(int client, float basePoint[3], float x1, float y1, float z1, float x2, float y2, float z2)
{
    ReturnTwoFloat val;
    float          viewAng[3], viewDirection[3];
    GetClientEyeAngles(client, viewAng);
    GetAngleVectors(viewAng, viewDirection, NULL_VECTOR, NULL_VECTOR);
    NormalizeVector(viewDirection, viewDirection);
    NegateVector(viewDirection);

    float localX[3], localY[3];
    float upVector[3] = { 0.0, 0.0, 1.0 };
    if (GetVectorDotProduct(viewDirection, upVector) > 0.99)
    {
        float rightVector[3] = { 0.0, 1.0, 0.0 };
        GetVectorCrossProduct(viewDirection, rightVector, localX);
    }
    else {
        GetVectorCrossProduct(viewDirection, upVector, localX);
    }
    NormalizeVector(localX, localX);

    GetVectorCrossProduct(localX, viewDirection, localY);
    NormalizeVector(localY, localY);

    float planeOffset1[3], planeOffset2[3];
    planeOffset1[0] = x1 * localX[0] + y1 * localY[0];
    planeOffset1[1] = x1 * localX[1] + y1 * localY[1];
    planeOffset1[2] = x1 * localX[2] + y1 * localY[2];
    planeOffset2[0] = x2 * localX[0] + y2 * localY[0];
    planeOffset2[1] = x2 * localX[1] + y2 * localY[1];
    planeOffset2[2] = x2 * localX[2] + y2 * localY[2];

    float verticalOffset1[3], verticalOffset2[3];
    verticalOffset1[0] = z1 * viewDirection[0];
    verticalOffset1[1] = z1 * viewDirection[1];
    verticalOffset1[2] = z1 * viewDirection[2];
    verticalOffset2[0] = z2 * viewDirection[0];
    verticalOffset2[1] = z2 * viewDirection[1];
    verticalOffset2[2] = z2 * viewDirection[2];

    val.startPt[0]     = basePoint[0] + planeOffset1[0] + verticalOffset1[0];
    val.startPt[1]     = basePoint[1] + planeOffset1[1] + verticalOffset1[1];
    val.startPt[2]     = basePoint[2] + planeOffset1[2] + verticalOffset1[2];
    val.endPt[0]       = basePoint[0] + planeOffset2[0] + verticalOffset2[0];
    val.endPt[1]       = basePoint[1] + planeOffset2[1] + verticalOffset2[1];
    val.endPt[2]       = basePoint[2] + planeOffset2[2] + verticalOffset2[2];
    return val;
}

void DrawNumber(float StartPos[3], float EndPos[3], int number, const int[] clients, int totals, float life, int colors[4], int speed, float width, float size)
{
    int totalPt = 0;
    int[] Ptid  = new int[18];
    switch (number)
    {
        case 0:
        {
            Ptid[totalPt++] = 1, Ptid[totalPt++] = 5, Ptid[totalPt++] = 0, Ptid[totalPt++] = 4;
            Ptid[totalPt++] = 0, Ptid[totalPt++] = 1, Ptid[totalPt++] = 4, Ptid[totalPt++] = 5;
        }
        case 1:
        {
            Ptid[totalPt++] = 1, Ptid[totalPt++] = 5;
        }
        case 2:
        {
            Ptid[totalPt++] = 0, Ptid[totalPt++] = 1, Ptid[totalPt++] = 1, Ptid[totalPt++] = 3;
            Ptid[totalPt++] = 3, Ptid[totalPt++] = 2, Ptid[totalPt++] = 2, Ptid[totalPt++] = 4, Ptid[totalPt++] = 4, Ptid[totalPt++] = 5;
        }
        case 3:
        {
            Ptid[totalPt++] = 0, Ptid[totalPt++] = 1, Ptid[totalPt++] = 1, Ptid[totalPt++] = 5;
            Ptid[totalPt++] = 5, Ptid[totalPt++] = 4, Ptid[totalPt++] = 2, Ptid[totalPt++] = 3;
        }
        case 4:
        {
            Ptid[totalPt++] = 0, Ptid[totalPt++] = 2, Ptid[totalPt++] = 2, Ptid[totalPt++] = 3;
            Ptid[totalPt++] = 1, Ptid[totalPt++] = 5;
        }
        case 5:
        {
            Ptid[totalPt++] = 0, Ptid[totalPt++] = 1, Ptid[totalPt++] = 0, Ptid[totalPt++] = 2;
            Ptid[totalPt++] = 3, Ptid[totalPt++] = 2, Ptid[totalPt++] = 3, Ptid[totalPt++] = 5, Ptid[totalPt++] = 4, Ptid[totalPt++] = 5;
        }
        case 6:
        {
            Ptid[totalPt++] = 0, Ptid[totalPt++] = 1, Ptid[totalPt++] = 0, Ptid[totalPt++] = 4;
            Ptid[totalPt++] = 3, Ptid[totalPt++] = 2, Ptid[totalPt++] = 3, Ptid[totalPt++] = 5, Ptid[totalPt++] = 4, Ptid[totalPt++] = 5;
        }
        case 7:
        {
            Ptid[totalPt++] = 0, Ptid[totalPt++] = 1, Ptid[totalPt++] = 1, Ptid[totalPt++] = 5;
        }
        case 8:
        {
            Ptid[totalPt++] = 0, Ptid[totalPt++] = 1, Ptid[totalPt++] = 1, Ptid[totalPt++] = 5;
            Ptid[totalPt++] = 3, Ptid[totalPt++] = 2, Ptid[totalPt++] = 4, Ptid[totalPt++] = 0, Ptid[totalPt++] = 4, Ptid[totalPt++] = 5;
        }
        case 9:
        {
            Ptid[totalPt++] = 0, Ptid[totalPt++] = 1, Ptid[totalPt++] = 1, Ptid[totalPt++] = 5;
            Ptid[totalPt++] = 3, Ptid[totalPt++] = 2, Ptid[totalPt++] = 2, Ptid[totalPt++] = 0, Ptid[totalPt++] = 4, Ptid[totalPt++] = 5;
        }
    }

    float fArray[6][3];
    fArray[1] = EndPos, fArray[1][2] = StartPos[2];
    fArray[2] = StartPos, fArray[2][2] = StartPos[2] - size;
    fArray[3] = EndPos, fArray[3][2] = EndPos[2] + size;
    fArray[4] = StartPos, fArray[4][2] = EndPos[2];
    fArray[0] = StartPos, fArray[5] = EndPos;
    for (int k = 0; k < 9; k++)
    {
        if (2 * k + 1 > totalPt)
            break;
        TE_SetupBeamPoints(fArray[Ptid[2 * k]], fArray[Ptid[2 * k + 1]], g_sprite, 0, 0, 0, life, width, width, 1, 0.0, colors, speed);
        TE_Send(clients, totals, 0.0);
    }
}

stock bool IsValidClient(int client)
{
    return 0 < client < MaxClients + 1 && IsClientInGame(client);
}

stock int GetWpnType(int weapon)
{
    char sClassName[64];
    GetEdictClassname(weapon, sClassName, sizeof sClassName);
    if (StrContains(sClassName, "inferno", false) != -1 || StrContains(sClassName, "entityflame", false) != -1)
        return 4;

    if (StrContains(sClassName, "hunting", false) != -1 || StrContains(sClassName, "sniper", false) != -1)
        return 0;

    if (StrContains(sClassName, "rifle", false) != -1 || StrContains(sClassName, "smg", false) != -1)
        return 1;

    if (StrContains(sClassName, "melee", false) != -1)
        return 2;

    if (StrContains(sClassName, "projectile", false) != -1)
        return 5;
    return 3;
}

void HandleShotgunDamage(int victim, int attacker, int weapon, int damage, int damagetype, const float damagePosition[3], bool b_forceHeadshot)
{
    if (g_ShotgunDamageBuffer[attacker][victim].isCreated)
    {
        g_ShotgunDamageBuffer[attacker][victim].totalDamage += damage;    // 出于数据准确性考虑，这也是游戏的计算方式
        if (b_forceHeadshot)
            g_ShotgunDamageBuffer[attacker][victim].isHeadshot = true;
    }
    else
    {
        g_ShotgunDamageBuffer[attacker][victim].victim            = victim;
        g_ShotgunDamageBuffer[attacker][victim].attacker          = attacker;
        g_ShotgunDamageBuffer[attacker][victim].totalDamage       = damage;
        g_ShotgunDamageBuffer[attacker][victim].damageType        = damagetype;
        g_ShotgunDamageBuffer[attacker][victim].weapon            = weapon;
        g_ShotgunDamageBuffer[attacker][victim].isHeadshot        = b_forceHeadshot;

        g_ShotgunDamageBuffer[attacker][victim].damagePosition[0] = damagePosition[0];
        g_ShotgunDamageBuffer[attacker][victim].damagePosition[1] = damagePosition[1];
        g_ShotgunDamageBuffer[attacker][victim].damagePosition[2] = damagePosition[2];

        DataPack pack                                             = new DataPack();
        pack.WriteCell(attacker);
        pack.WriteCell(victim);
        g_ShotgunDamageBuffer[attacker][victim].isCreated = true;
        RequestFrame(NextFrame_ShowShotgunDamage, pack);
    }
}

void NextFrame_ShowShotgunDamage(DataPack pack)
{
    pack.Reset();
    int attacker = pack.ReadCell();
    int victim   = pack.ReadCell();
    delete pack;

    if (!IsValidClient(attacker) || !IsValidClient(victim))
    {
        g_ShotgunDamageBuffer[attacker][victim].isCreated = false;
        return;
    }

    if (g_ShotgunDamageBuffer[attacker][victim].totalDamage > 0)
    {
        float tempPosition[3];
        tempPosition[0] = g_ShotgunDamageBuffer[attacker][victim].damagePosition[0];
        tempPosition[1] = g_ShotgunDamageBuffer[attacker][victim].damagePosition[1];
        tempPosition[2] = g_ShotgunDamageBuffer[attacker][victim].damagePosition[2];

        DisplayDamage(victim, attacker, g_ShotgunDamageBuffer[attacker][victim].weapon,
                      g_ShotgunDamageBuffer[attacker][victim].totalDamage,
                      g_ShotgunDamageBuffer[attacker][victim].damageType,
                      tempPosition, g_ShotgunDamageBuffer[attacker][victim].isHeadshot);

        g_ShotgunDamageBuffer[attacker][victim].totalDamage = 0;
        g_ShotgunDamageBuffer[attacker][victim].isHeadshot  = false;
    }
    g_ShotgunDamageBuffer[attacker][victim].isCreated = false;
}

void DisplayDamage(int victim, int attacker, int weapon, int damage, int damagetype, const float damagePosition[3], bool forceHeadshot = false, bool UpdateFrame = false)
{
    if(!IsValidClient(attacker) || !IsValidClient(victim))
        return;

    int zombieClass = GetEntProp(victim, Prop_Send, "m_zombieClass");
    if (g_iadd == 1 && !UpdateFrame)
    {
        if (!g_SumShowMode[attacker][victim].needShow || !g_SumShowMode[attacker][0].needShow)
        {
            g_SumShowMode[attacker][victim].needShow     = true;
            g_SumShowMode[attacker][0].needShow          = true;
            g_SumShowMode[attacker][victim].lastShowTime = 0.0;
            g_SumShowMode[attacker][victim].totalDamage  = damage;
            g_bNeverFire[attacker]                       = false;
        }
        else
            g_SumShowMode[attacker][victim].totalDamage += damage;
        g_SumShowMode[attacker][victim].damagePosition[0] = damagePosition[0];
        g_SumShowMode[attacker][victim].damagePosition[1] = damagePosition[1];
        g_SumShowMode[attacker][victim].damagePosition[2] = damagePosition[2];
        g_SumShowMode[attacker][victim].damageType        = damagetype;
        g_SumShowMode[attacker][victim].weapon            = weapon;
        g_SumShowMode[attacker][victim].isHeadshot        = forceHeadshot;
        float now_time                                    = GetGameTime();
        if (IsPlayerAlive(victim))
        {
            if (zombieClass == ZC_TANK)
                now_time = now_time + 3.0;
            else if (PlayerDataArray[attacker].wpn_type == 3)
                now_time = now_time + 0.5;
        }
        g_SumShowMode[attacker][victim].lastHitTime = now_time;
        g_SumShowMode[attacker][0].lastHitTime      = now_time;    // 最新
        return;
    }

    if (PlayerDataArray[attacker].wpn_id != weapon && weapon != -1 && IsValidEdict(weapon))
    {
        PlayerDataArray[attacker].wpn_id   = weapon;
        PlayerDataArray[attacker].wpn_type = GetWpnType(weapon);
    }

    int total     = 0;
    int[] clients = new int[MaxClients];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidClient(i))
        {
            if (i == attacker || PlayerDataArray[i].show_other)
                clients[total++] = i;
        }
    }

    if (zombieClass == ZC_TANK && (GetEntProp(victim, Prop_Send, "m_isIncapacitated") == 1 || g_fTankIncap[victim] + 1.0 > GetGameTime()))
    {
        g_fTankIncap[victim] = GetGameTime();
        return;
    }

    int val = damage;
    if (val < 2 && PlayerDataArray[attacker].wpn_type == 5)
        return;

    int colors[4], colorIndex;
    if ((damagetype & DMG_HEADSHOT) || forceHeadshot)
        colorIndex = 4;
    else if (GetClientTeam(victim) == 2)
        colorIndex = 0;
    else
        colorIndex = 2;    // GetRandomInt(1, 3)
    for (int i = 0; i < 3; i++)
        colors[i] = color[colorIndex][i];
    colors[3] = g_iAlpha;

    float life;
    switch (PlayerDataArray[attacker].wpn_type)
    {
        case 0: life = 0.8;
        case 1: life = 0.2;
        case 2: life = 0.6;
        case 3: life = 0.75;
        case 4: life = 0.1;
        case 5: life = 1.5;
    }
    if (zombieClass == ZC_BOOMER)
        life = life < 0.5 ? 0.5 : life;
    if (UpdateFrame)
        life = UPDATE_INTERVAL;
    if(forceHeadshot)
    {
        g_SumShowMode[attacker][victim].needShow = false;
        float temp_life = g_SumShowMode[attacker][victim].lastHitTime + 0.5 - GetGameTime();
        life = temp_life > 0.5 ? temp_life : 0.5;
    }

    float z_distance = 40.0, distance, gap, size, width, vecPos[3], vecOrg[3];
    GetEntPropVector(attacker, Prop_Send, "m_vecOrigin", vecPos);
    GetEntPropVector(victim, Prop_Send, "m_vecOrigin", vecOrg);
    gap      = g_fgap;
    size     = g_fsize;
    width    = 0.8;
    distance = GetVectorDistance(vecPos, vecOrg, true);
    if (distance > g_f_show_distance * g_f_show_distance && GetEntProp(attacker, Prop_Send, "m_hZoomOwner") == -1)
        return;

    bool is_near = false;
    if (distance <= 120.0 * 120.0)
    {
        float scale = 120.0 * 120.0 / distance;
        scale       = scale < 4.0 ? scale : 4.0;
        gap         = gap / scale;
        size        = size / scale;
        z_distance  = 1.0;
        width       = 0.8 / scale;
        is_near     = true;
    }
    else if (distance > 70.0 * 70.0 * 100.0)
    {
        float scale = distance / (70.0 * 70.0 * 100.0);
        scale       = scale > 2.0 ? 2.0 : scale;
        gap         = gap * scale;
        size        = size * scale;
        width       = width * scale;
    }

    float damageorg[3];
    damageorg = damagePosition;
    if (damageorg[0] == 0.0 || PlayerDataArray[attacker].wpn_type == 2 || PlayerDataArray[attacker].wpn_type == 5)
    {
        damageorg = vecOrg;
        if (!is_near)
        {
            damageorg[0] = damageorg[0] + GetRandomFloat(-20.0, 20.0);
            damageorg[1] = damageorg[1] + GetRandomFloat(-20.0, 20.0);
        }
        damageorg[2] = damageorg[2] + 56.0;
    }

    int   count      = PrintDigitsInOrder(val);
    int   divisor    = 1;
    float half_width = size * float(count) / 2.0, x_start, scale;
    scale            = damagePosition[0] < vecOrg[0] ? -1.0 : 1.0;
    if (is_near)
        scale = 0.0;
    for (int i = 1; i < count; i++)
        divisor *= 10;
    for (int i = 0; i < count; i++)
    {
        if (i == 0)
            x_start = half_width;
        float          x_end = x_start - size;
        int            digit = val / divisor;
        ReturnTwoFloat fval;
        fval = CalculatePoint(attacker, damageorg, x_start + scale * g_f_x_offset, g_f_y_offset + size, z_distance,
                              x_end + scale * g_f_x_offset, g_f_y_offset - size, z_distance);
        DrawNumber(fval.startPt, fval.endPt, digit, clients, total, life, colors, 1, width, size);
        val %= divisor;
        divisor /= 10;
        x_start = x_start - size - gap;
    }
}

public void OnGameFrame()
{
    if (g_iadd == 1)
    {
        for (int i = 1; i <= L4D2_MAXPLAYERS; i++)
        {
            if (g_bNeverFire[i])
                continue;

            if (!IsValidEdict(i) || !IsClientInGame(i) || !IsPlayerAlive(i) || g_SumShowMode[i][0].lastHitTime + 0.5 < GetGameTime())
            {
                g_bNeverFire[i]              = true;
                g_SumShowMode[i][0].needShow = false;
                continue;
            }

            for (int j = 1; j <= L4D2_MAXPLAYERS; j++)
            {
                if (g_SumShowMode[i][j].needShow && g_SumShowMode[i][j].lastShowTime + UPDATE_INTERVAL < GetGameTime())
                {
                    if (g_SumShowMode[i][j].lastHitTime + 0.5 < GetGameTime())
                    {
                        g_SumShowMode[i][j].needShow = false;
                        g_SumShowMode[i][j].totalDamage = 0;
                        continue;
                    }
                    else
                    {
                        DisplayDamage(j, i, g_SumShowMode[i][j].weapon, g_SumShowMode[i][j].totalDamage,
                                      g_SumShowMode[i][j].damageType, g_SumShowMode[i][j].damagePosition, g_SumShowMode[i][j].isHeadshot, true);
                        g_SumShowMode[i][j].lastShowTime = GetGameTime();
                    }
                }
            }
        }
    }
}
