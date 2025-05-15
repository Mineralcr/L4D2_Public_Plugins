/**
 * 原版: https://forums.alliedmods.net/showthread.php?t=334463
 * 
 * phys_bone_follower 是一個實體，會占Server空間的2048個位子
 * 由prop_dynamic_override或是prop_dynamic所產生的延伸實體 (通常產生數十個)
 * 用於環繞物件產生更貼近物體的碰撞體積
 * 常見於三方圖，譬如兵馬俑, 會飛行的鳥, 會動的恐龍
 * phys_bone_follower會有大量數據傳送給玩家導致net_graph 4看到的圖示上漲
 * 
 * 插件原理: 使用SDKHook_SetTransmit隱藏phys_bone_follower實體可技術性停止傳輸數據給玩家
 * -沒有真的刪除phys_bone_follower，所以不會導致模型沒有碰撞
 * -依然有碰撞，但是因為使用SDKHook_SetTransmit隱藏phys_bone_follower實體，所以當玩家經過phys_bone_follower時會產生上下窜動的視野，別人看你是正常的
 * -(此插件新增的方法)為避免上下窜動的視野，使用SDKHook_TouchPost檢測玩家碰到phys_bone_follower的父物件時(prop_dynamic_override或是prop_dynamic)，暫時停止SDKHook_SetTransmit運作
 * 
 * 之所以用插件不用stripper 因為
 * l4d1/2 無法使用DisableBoneFollowers
 * 
 * 如果刪除phys_bone_follower會導致模型沒有碰撞
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>

#define MAXENTITIES                   2048

ConVar
    g_hCvar_LagSwitch;

int
    g_iLagSwitch;

float
    g_fTransmitRules[MAXENTITIES+1][MAXPLAYERS+1];

public Plugin myinfo =
{
    name        = "Map Lag Plus Plus",
    author      = "洛琪",
    description = "Map Lag Plus Version. 修复了爆in炸ping问题，修复了视角上下抖动的问题",
    version     = "1.1",
    url         = "https://steamcommunity.com/profiles/76561198812009299/"
};

public void OnPluginStart()
{
    g_hCvar_LagSwitch = CreateConVar("lag_switch", "1", "是否开启此插件？1开启，0关闭", FCVAR_NONE, true, 0.0, true, 1.0);
    HookEvent("round_start_pre_entity", Event_RoundStartPre);
    g_hCvar_LagSwitch.AddChangeHook(ConVarChanged);
    AutoExecConfig(true, "map_lag_preventor_plus");
}

public void OnConfigsExecuted()
{
    GetCvars();
}

void ConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    GetCvars();
}

void GetCvars()
{
    g_iLagSwitch = g_hCvar_LagSwitch.IntValue;
}

void Event_RoundStartPre(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 0; i <= MaxClients; i++)
    {
        for (int j = 0; j <= MAXENTITIES; j++)
        {
            g_fTransmitRules[j][i] = 0.0;
        }
    }
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (!IsValidEntityIndex(entity))
        return;

    switch (classname[0])
    {
        case 'p':
        {
            if (StrEqual(classname, "phys_bone_follower"))
            {
                RequestFrame(OnNextFrame, EntIndexToEntRef(entity));
            }
        }
    }
}

void OnNextFrame(int entityRef)
{
    int entity = EntRefToEntIndex(entityRef);
    if (entity == INVALID_ENT_REFERENCE)
        return;

    SDKHook(entity, SDKHook_SetTransmit, TransmitRules);

    int owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
    if(owner > MaxClients && IsValidEntity(owner))
    {
        int ref = EntIndexToEntRef(owner);
        CreateTimer(0.1, Timer_DelaySDK, ref, TIMER_FLAG_NO_MAPCHANGE);
    }
}

Action Timer_DelaySDK(Handle Timer, int ref)
{
    int entity = EntRefToEntIndex(ref);
    if (entity == INVALID_ENT_REFERENCE)
        return Plugin_Continue;

    SDKUnhook(entity, SDKHook_TouchPost, SDK_OnTouchPost);
    SDKHook(entity, SDKHook_TouchPost, SDK_OnTouchPost);
    return Plugin_Continue;
}

Action TransmitRules(int iEntity, int iClient)
{
    if (g_iLagSwitch == 0)
        return Plugin_Continue;

    if (!IsFakeClient(iClient))
    {
        int owner = GetEntPropEnt(iEntity, Prop_Send, "m_hOwnerEntity");
        if (g_fTransmitRules[owner][iClient] + 1.0 < GetGameTime())
            return Plugin_Handled;
    }

    return Plugin_Continue;
}

void SDK_OnTouchPost(int entity, int other)
{
    if (g_iLagSwitch == 0)
        return;

    if (other > 0 && other <= MaxClients)
    {
        if (IsFakeClient(other))
            return;
        g_fTransmitRules[entity][other] = GetGameTime();
    }
}

bool IsValidEntityIndex(int entity)
{
    return (MaxClients+1 <= entity <= GetMaxEntities());
}