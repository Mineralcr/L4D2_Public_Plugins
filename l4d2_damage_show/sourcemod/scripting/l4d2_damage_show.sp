#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>

#define PLUGIN_VERSION  "1.1"
#define SPRITE_MATERIAL "materials/sprites/laserbeam.vmt"
#define DMG_HEADSHOT    1 << 30
#define L4D2_MAXPLAYERS 32
#define ZC_CHARGER      6

int g_sprite;

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

PlayerSetData
    PlayerDataArray[L4D2_MAXPLAYERS + 1];

ConVar
    g_hcvar_maxtempentities,
    g_hcvar_plugin_mode,
    g_hcvar_size,
    g_hcvar_gap;

int
    g_iMode;
float
    g_fsize,
    g_fgap;

static const int color[][] = {
    {0,    255, 0,   100}, // 绿色
    { 255, 255, 0,   100}, // 黄色
    { 255, 255, 255, 100}, // 白色
    { 0,   255, 255, 100}, // 蓝色
    { 255, 0,   0,   100}  // 红色
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
    g_hcvar_plugin_mode.AddChangeHook(ConVarChanged);
    g_hcvar_size.AddChangeHook(ConVarChanged);
    g_hcvar_gap.AddChangeHook(ConVarChanged);

    AutoExecConfig(true, "l4d2_damage_show");
    HookEvent("player_left_safe_area", Event_LeftSafeArea, EventHookMode_PostNoCopy);
    InItVarNum(-1);
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
    g_iMode = g_hcvar_plugin_mode.IntValue;
    g_fsize = g_hcvar_size.FloatValue;
    g_fgap  = g_hcvar_gap.FloatValue;
}

public void OnMapStart()
{
    g_sprite = PrecacheModel(SPRITE_MATERIAL, true);
}

void InItVarNum(int client)
{
    if(client == -1)
    {
        for (int i = 0; i <= L4D2_MAXPLAYERS; i++)
        {
            PlayerDataArray[i].wpn_id        = -1;
            PlayerDataArray[i].wpn_type      = -1;
            PlayerDataArray[i].plugin_switch = true;
            PlayerDataArray[i].show_other    = false;
            PlayerDataArray[i].last_set_time = 0.0;
        }
    }
    else
    {
        PlayerDataArray[client].wpn_id        = -1;
        PlayerDataArray[client].wpn_type      = -1;
        PlayerDataArray[client].plugin_switch = true;
        PlayerDataArray[client].show_other    = false;
        PlayerDataArray[client].last_set_time = 0.0;
    }
    g_hcvar_maxtempentities.SetInt(512);
}

void Event_LeftSafeArea(Event event, const char[] name, bool dontBroadcast)
{
    PrintToChatAll("\x04[伤害显示]:\x05同时按下Tab键+R键可切换伤害显示模式.");
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
        }
        else
        {
            if (!PlayerDataArray[client].show_other)
            {
                PlayerDataArray[client].show_other = true;
                PrintToChat(client, "\x04[伤害显示]\x05当前模式:伤害显示开、他人显示开.");
            }
            else
            {
                PlayerDataArray[client].plugin_switch = false;
                PlayerDataArray[client].show_other    = false;
                PrintToChat(client, "\x04[伤害显示]\x05当前模式:伤害显示关.");
            }
        }
    }
}

public void OnClientPutInServer(int client)
{
    InItVarNum(client);
    SDKHook(client, SDKHook_OnTakeDamagePost, SDK_OnTakeDamagePost);
}

void SDK_OnTakeDamagePost(int victim, int attacker, int inflictor, float damage, int damagetype, int weapon, const float damageForce[3], const float damagePosition[3])
{
    if(g_iMode == 0)
        return;
    
    if (IsValidClient(victim) && IsValidClient(attacker) && GetClientTeam(attacker) == 2 && !IsFakeClient(attacker))
    {
        if (!PlayerDataArray[attacker].plugin_switch)
            return;
        
        if(g_iMode == 3 || g_iMode & (1 << 0) && GetClientTeam(victim) == 3 || g_iMode & (1 << 1) && GetClientTeam(victim) == 2)
        {
            int wpn;
            wpn = weapon == -1 ? inflictor : weapon;
            if (PlayerDataArray[attacker].wpn_id != wpn)
            {
                PlayerDataArray[attacker].wpn_id   = wpn;
                PlayerDataArray[attacker].wpn_type = GetWpnType(wpn);
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

            float f_damage = damage;
            int zombieClass = GetEntProp(victim, Prop_Send, "m_zombieClass");
            if (zombieClass == ZC_CHARGER)
            {
                int abilityEnt = GetEntPropEnt(victim, Prop_Send, "m_customAbility");
                if (IsValidEntity(abilityEnt) && GetEntProp(abilityEnt, Prop_Send, "m_isCharging") > 0)
                {
                    f_damage = f_damage / 3.0;
                }
            }
            int val = RoundToFloor(f_damage);
            if (val < 2)
                return;

            int colors[4];
            if (damagetype & DMG_HEADSHOT)
                colors = color[4];
            else
                colors = color[GetRandomInt(0, 3)];

            float life;
            switch (PlayerDataArray[attacker].wpn_type)
            {
                case 0: life = 0.8;
                case 1: life = 0.2;
                case 2: life = 0.6;
                case 3: life = 0.75;
                case 4: life = 0.1;
            }

            float z_distance = 40.0, distance, gap, size, width, vecPos[3], vecOrg[3];
            GetEntPropVector(attacker, Prop_Send, "m_vecOrigin", vecPos);
            GetEntPropVector(victim, Prop_Send, "m_vecOrigin", vecOrg);
            gap      = g_fgap;
            size     = g_fsize;
            width    = 0.8;
            distance = GetVectorDistance(vecPos, vecOrg, true);
            if (distance <= 60.0 * 60.0)
            {
                gap        = gap / 2.0;
                size       = size / 2.0;
                z_distance = 1.0;
                width      = 0.4;
            }
            else if (distance > 60.0 * 60.0 * 100.0)
            {
                float scale = distance / (60.0 * 60.0 * 100.0);
                scale       = scale > 2.0 ? 2.0 : scale;
                gap         = gap * scale;
                size        = size * scale;
                width       = width * scale;
            }

            float damageorg[3];
            damageorg = damagePosition;
            if (damageorg[0] == 0.0 || PlayerDataArray[attacker].wpn_type == 2)
            {
                damageorg    = vecOrg;
                damageorg[0] = damageorg[0] + GetRandomFloat(-20.0, 20.0);
                damageorg[1] = damageorg[1] + GetRandomFloat(-20.0, 20.0);
                damageorg[2] = damageorg[2] + 56.0;
            }

            int   count      = PrintDigitsInOrder(val);
            int   divisor    = 1;
            float half_width = size * float(count) / 2.0, x_start;
            for (int i = 1; i < count; i++)
                divisor *= 10;
            for (int i = 0; i < count; i++)
            {
                if (i == 0)
                    x_start = half_width;
                float          x_end = x_start - size;
                int            digit = val / divisor;
                ReturnTwoFloat fval;
                fval = CalculatePoint(attacker, damageorg, x_start, size, z_distance, x_end, size * -1.0, z_distance);
                DrawNumber(fval.startPt, fval.endPt, digit, clients, total, life, colors, 1, width, size);
                val %= divisor;
                divisor /= 10;
                x_start = x_start - size - gap;
            }
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
    float p1[3], p2[3], p3[3], p4[3];
    p1 = EndPos, p1[2] = StartPos[2];
    p2 = StartPos, p2[2] = StartPos[2] - size;
    p3 = EndPos, p3[2] = EndPos[2] + size;
    p4 = StartPos, p4[2] = EndPos[2];
    if (number == 2 || number == 3 || number == 4 || number == 5 || number == 6 || number == 8 || number == 9)
    {
        TE_SetupBeamPoints(p2, p3, g_sprite, 0, 0, 0, life, width, width, 1, 0.0, colors, speed);
        TE_Send(clients, totals, 0.0);
    }
    if (number == 0 || number == 1 || number == 3 || number == 4 || number == 5 || number == 6 || number == 7 || number == 8 || number == 9)
    {
        TE_SetupBeamPoints(p3, EndPos, g_sprite, 0, 0, 0, life, width, width, 1, 0.0, colors, speed);
        TE_Send(clients, totals, 0.0);
    }
    if (number == 0 || number == 2 || number == 3 || number == 5 || number == 6 || number == 8 || number == 9)
    {
        TE_SetupBeamPoints(EndPos, p4, g_sprite, 0, 0, 0, life, width, width, 1, 0.0, colors, speed);
        TE_Send(clients, totals, 0.0);
    }
    if (number == 0 || number == 2 || number == 6 || number == 8)
    {
        TE_SetupBeamPoints(p4, p2, g_sprite, 0, 0, 0, life, width, width, 1, 0.0, colors, speed);
        TE_Send(clients, totals, 0.0);
    }
    if (number == 0 || number == 4 || number == 5 || number == 6 || number == 8 || number == 9)
    {
        TE_SetupBeamPoints(p2, StartPos, g_sprite, 0, 0, 0, life, width, width, 1, 0.0, colors, speed);
        TE_Send(clients, totals, 0.0);
    }
    if (number == 0 || number == 2 || number == 3 || number == 5 || number == 6 || number == 7 || number == 8 || number == 9)
    {
        TE_SetupBeamPoints(StartPos, p1, g_sprite, 0, 0, 0, life, width, width, 1, 0.0, colors, speed);
        TE_Send(clients, totals, 0.0);
    }
    if (number == 0 || number == 1 || number == 2 || number == 3 || number == 4 || number == 7 || number == 8 || number == 9)
    {
        TE_SetupBeamPoints(p1, p3, g_sprite, 0, 0, 0, life, width, width, 1, 0.0, colors, speed);
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
    return 3;
}
