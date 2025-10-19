#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <left4dhooks>

#define SPRITE_MATERIAL "materials/sprites/laserbeam.vmt"
#define PARTICLE_BOMB1  "explosion_huge"
#define PARTICLE_BOMB2  "missile_hit1"
#define PARTICLE_BOMB3  "gas_explosion_main"
#define SOUND_EXPLODE3  "weapons/hegrenade/explode3.wav"
#define SOUND_EXPLODE4  "weapons/hegrenade/explode4.wav"
#define SOUND_EXPLODE5  "weapons/hegrenade/explode5.wav"

StringMap g_sAttachMentMax;

enum struct UpdatePos
{
    int   target;
    int   update;
    int   cooldown;
    float SubPosition[3];
}

enum struct ReturnTwoFloat
{
    float startPt[3];
    float endPt[3];
}

UpdatePos
    g_TargetEnt[2048];

bool
    g_bPipeBomb_Map[2048],
    g_bInfectedWitch_Map[2048];

int
    g_sprite;

float
    g_fDamageRange,
    g_fDamage;

ConVar
    g_hcvar_pipe_bomb_timer_duration,
    g_hcvar_DamageRange,
    g_hcvar_Damage;

public Plugin myinfo =
{
    name        = "l4d2_sticky_pipe_bomb",
    author      = "77, 几把洛琪o",
    description = "粘性手雷",
    version     = "1.2",
    url         = ""
};

public void OnPluginStart()
{
    g_hcvar_pipe_bomb_timer_duration = FindConVar("pipe_bomb_timer_duration");
    g_hcvar_DamageRange              = CreateConVar("cf_pipe_bomb_range", "500.0", "粘性手雷伤害半径", FCVAR_NONE, true, 0.0, true, 10000.0);
    g_hcvar_Damage                   = CreateConVar("cf_pipe_bomb_damage", "1000.0", "粘性手雷伤害大小", FCVAR_NONE, true, 0.0, true, 10000.0);
    g_hcvar_DamageRange.AddChangeHook(ConVarChanged);
    g_hcvar_Damage.AddChangeHook(ConVarChanged);
    InItStringMap();
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
    g_fDamageRange = g_hcvar_DamageRange.FloatValue;
    g_fDamage      = g_hcvar_Damage.FloatValue;
}

public void OnMapStart()
{
    g_sprite = PrecacheModel(SPRITE_MATERIAL, true);
    PrecacheSound(SOUND_EXPLODE3);
    PrecacheSound(SOUND_EXPLODE4);
    PrecacheSound(SOUND_EXPLODE5);
}

// sttschment点位上限
void InItStringMap()
{
    delete g_sAttachMentMax;
    g_sAttachMentMax = new StringMap();
    g_sAttachMentMax.SetValue("models/survivors/survivor_adawong.mdl", 30);
    g_sAttachMentMax.SetValue("models/survivors/survivor_biker.mdl", 33);
    g_sAttachMentMax.SetValue("models/survivors/survivor_biker_light.mdl", 32);
    g_sAttachMentMax.SetValue("models/survivors/survivor_coach.mdl", 27);
    g_sAttachMentMax.SetValue("models/survivors/survivor_gambler.mdl", 29);
    g_sAttachMentMax.SetValue("models/survivors/survivor_manager.mdl", 26);
    g_sAttachMentMax.SetValue("models/survivors/survivor_mechanic.mdl", 31);
    g_sAttachMentMax.SetValue("models/survivors/survivor_namvet.mdl", 29);
    g_sAttachMentMax.SetValue("models/survivors/survivor_producer.mdl", 30);
    g_sAttachMentMax.SetValue("models/survivors/survivor_teenangst.mdl", 28);
    g_sAttachMentMax.SetValue("models/survivors/survivor_teenangst_light.mdl", 27);
    g_sAttachMentMax.SetValue("models/infected/boomer.mdl", 3);
    g_sAttachMentMax.SetValue("models/infected/boomette.mdl", 3);
    g_sAttachMentMax.SetValue("models/infected/charger.mdl", 5);
    g_sAttachMentMax.SetValue("models/infected/hulk.mdl", 10);
    g_sAttachMentMax.SetValue("models/infected/hulk_dlc3.mdl", 10);
    g_sAttachMentMax.SetValue("models/infected/hunter.mdl", 5);
    g_sAttachMentMax.SetValue("models/infected/smoker.mdl", 4);
    g_sAttachMentMax.SetValue("models/infected/spitter.mdl", 5);
    g_sAttachMentMax.SetValue("models/infected/witch.mdl", 9);
    // 普通僵尸默认 14
}

public void OnEntityCreated(int entity, const char[] classname)
{
    switch (classname[0])
    {
        case 'i':
        {
            if (StrEqual(classname, "infected", false))
                g_bInfectedWitch_Map[entity] = true;
        }
        case 'w':
        {
            if (StrEqual(classname, "witch", false))
                g_bInfectedWitch_Map[entity] = true;
        }
        case 'p':
        {
            if (StrEqual(classname, "pipe_bomb_projectile", false))
                SDKHook(entity, SDKHook_SpawnPost, SDK_PipeBombSpawnPost);
        }
    }
}

public void OnEntityDestroyed(int entity)
{
    if (MaxClients < entity < 2048)
    {
        g_bInfectedWitch_Map[entity] = false;
        g_bPipeBomb_Map[entity]      = false;
    }
}

void SDK_PipeBombSpawnPost(int entity)
{
    if (!IsValidEntity(entity))
        return;

    int owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
    if (owner > 0 && IsSurvivor(owner))
    {
        SDKHook(entity, SDKHook_ShouldCollide, SDK_PipeBombCollide);
        SDKHook(entity, SDKHook_Touch, SDK_PipeBombTouch);
    }
    g_bPipeBomb_Map[entity] = true;
    SDKUnhook(entity, SDKHook_SpawnPost, SDK_PipeBombSpawnPost);
}

// 和玩家与npc的碰撞
bool SDK_PipeBombCollide(int entity, int collisiongroup, int contentsmask, bool originalResult)
{
    if (contentsmask & MASK_PLAYERSOLID || contentsmask & MASK_PLAYERSOLID_BRUSHONLY || contentsmask & MASK_NPCSOLID || contentsmask & MASK_NPCSOLID_BRUSHONLY)
    {
        if (IsValidEdict(entity))
        {
            int target = FindByOriginNearest(entity);
            if (IsValidEdict(target))
            {
                TelepToNearestAttachment(entity, target);
                StickEntity(entity, target);
            }
        }
    }
    return originalResult;
}

// 和其他实体碰撞
void SDK_PipeBombTouch(int entity, int other)
{
    if (!IsValidEntity(entity))
        return;

    if (IsValidEntity(other) && !IsTrigger(other))
        StickEntity(entity, other);
}

void StickEntity(int entity, int target)
{
    if (!IsValidEntity(entity) || !IsValidEntity(target))
        return;

    float setSpeed[3] = { 0.0, 0.0, 0.0 };
    TeleportEntity(entity, NULL_VECTOR, NULL_VECTOR, setSpeed);
    SetEntityGravity(entity, 0.0001);
    SetEntityMoveType(entity, MOVETYPE_NONE);
    SetEntityCollisionGroup(entity, 1);    // COLLISION_GROUP_DEBRIS
    AcceptEntityInput(entity, "DisableCollision");

    g_TargetEnt[entity].target = EntIndexToEntRef(target);
    float vec1[3], vec2[3], result[3];
    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", vec1);
    GetEntPropVector(target, Prop_Send, "m_vecOrigin", vec2);
    SubtractVectors(vec1, vec2, result);
    g_TargetEnt[entity].SubPosition = result;

    SDKUnhook(entity, SDKHook_Touch, SDK_PipeBombTouch);
    SDKUnhook(entity, SDKHook_ShouldCollide, SDK_PipeBombCollide);

    g_TargetEnt[entity].update   = 0;
    g_TargetEnt[entity].cooldown = g_hcvar_pipe_bomb_timer_duration.IntValue;
    SDKHook(entity, SDKHook_ThinkPost, SDK_PipeBombThink);
    CreateTimer(0.2, Update_TE, EntIndexToEntRef(entity), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

// 位置同步
void SDK_PipeBombThink(int entity)
{
    if (!IsValidEntity(entity))
        return;

    int target = EntRefToEntIndex(g_TargetEnt[entity].target);
    if (IsValidEntity(target))
    {
        float vec1[3], vec2[3];
        GetEntPropVector(target, Prop_Send, "m_vecOrigin", vec1);
        AddVectors(vec1, g_TargetEnt[entity].SubPosition, vec2);
        TeleportEntity(entity, vec2, NULL_VECTOR, NULL_VECTOR);
        SetEntProp(entity, Prop_Data, "m_nNextThinkTick", GetGameTickCount() + 1);
        if (target == 0)
            SDKUnhook(entity, SDKHook_ThinkPost, SDK_PipeBombThink);
    }
}

// TE效果
Action Update_TE(Handle timer, int entity)
{
    entity = EntRefToEntIndex(entity);
    if (!IsValidEntity(entity))
        return Plugin_Stop;

    g_TargetEnt[entity].update += 1;
    if (g_TargetEnt[entity].update % 5 == 0 || g_TargetEnt[entity].update == 1)
    {
        g_TargetEnt[entity].cooldown -= 1;
        SendCoolDown_TENumber(entity, g_TargetEnt[entity].cooldown);
    }
    SendCircle_TE(entity);
    return Plugin_Continue;
}

// 手雷爆炸结算
public Action L4D_PipeBomb_Detonate(int entity, int client)
{
    if (g_bPipeBomb_Map[entity])
    {
        if (client == -1)
            client = 0;

        char  sBuffer[96];
        float vec1[3], vOrigin[3];
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", vec1);
        for (int i = 1; i < GetEntityCount(); i++)
        {
            if (!IsValidEdict(i))
                continue;

            if ((i <= MaxClients && IsClientInGame(i) && GetClientTeam(i) != 2) || g_bInfectedWitch_Map[i])
            {
                GetEntPropVector(i, Prop_Send, "m_vecOrigin", vOrigin);
                if (FloatAbs(vOrigin[0] - vec1[0]) < g_fDamageRange)
                {
                    if (i <= MaxClients)
                    {
                        Format(sBuffer, sizeof(sBuffer), "EntIndexToHScript(%d).Stagger(Vector(%f,%f,%f))", i, vec1[0], vec1[1], vec1[2]);
                        L4D2_ExecVScriptCode(sBuffer);
                    }
                    if (GetVectorDistance(vOrigin, vec1, true) < g_fDamageRange * g_fDamageRange)
                    {
                        SDKHooks_TakeDamage(i, client, entity, g_fDamage, DMG_BLAST);
                    }
                }
            }
        }
        CreateExpEffect(vec1);
    }
    return Plugin_Continue;
}

//---------------------------------辅助函数-------------------------------------------

void CreateExpEffect(float vPos[3])
{
    PhysicsExplode(vPos, 100, g_fDamageRange, false);
    
    int entity = CreateEntityByName("info_particle_system");
    if (entity != -1)
    {
        int random = GetRandomInt(1, 3);

        switch (random)
        {
            case 1: DispatchKeyValue(entity, "effect_name", PARTICLE_BOMB1);
            case 2: DispatchKeyValue(entity, "effect_name", PARTICLE_BOMB2);
            case 3: DispatchKeyValue(entity, "effect_name", PARTICLE_BOMB3);
        }

        DispatchSpawn(entity);
        ActivateEntity(entity);
        AcceptEntityInput(entity, "start");

        TeleportEntity(entity, vPos, NULL_VECTOR, NULL_VECTOR);

        SetVariantString("OnUser1 !self:Kill::1.0:1");
        AcceptEntityInput(entity, "AddOutput");
        AcceptEntityInput(entity, "FireUser1");
    }

    int shake = CreateEntityByName("env_shake");
    if (shake != -1)
    {
        char sTemp[16];
        DispatchKeyValue(shake, "spawnflags", "8");
        DispatchKeyValue(shake, "amplitude", "16.0");
        DispatchKeyValue(shake, "frequency", "1.5");
        DispatchKeyValue(shake, "duration", "0.9");
        IntToString(RoundToNearest(g_fDamageRange), sTemp, sizeof(sTemp));
        DispatchKeyValue(shake, "radius", sTemp);
        DispatchSpawn(shake);
        ActivateEntity(shake);
        AcceptEntityInput(shake, "Enable");

        TeleportEntity(shake, vPos, NULL_VECTOR, NULL_VECTOR);
        AcceptEntityInput(shake, "StartShake");
        RemoveEdict(shake);
    }

    int random = GetRandomInt(0, 2);
    if (random == 0)
        EmitSoundToAll(SOUND_EXPLODE3, entity, SNDCHAN_AUTO, SNDLEVEL_HELICOPTER);
    else if (random == 1)
        EmitSoundToAll(SOUND_EXPLODE4, entity, SNDCHAN_AUTO, SNDLEVEL_HELICOPTER);
    else if (random == 2)
        EmitSoundToAll(SOUND_EXPLODE5, entity, SNDCHAN_AUTO, SNDLEVEL_HELICOPTER);
}

int FindByOriginNearest(int entity)
{
    int   iNearest = -1;
    float vPos[3], cPos[3], Distance, minDistance = 9999999.0;
    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", vPos);
    int owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
    for (int i = 1; i < GetEntityCount(); i++)
    {
        if (!IsValidEdict(i))
            continue;

        if ((i <= MaxClients && IsClientInGame(i) && i != owner) || g_bInfectedWitch_Map[i])
        {
            GetEntPropVector(i, Prop_Send, "m_vecOrigin", cPos);
            Distance = GetVectorDistance(vPos, cPos, true);
            if (Distance < minDistance)
            {
                minDistance = Distance;
                iNearest    = i;
            }
        }
    }

    if (minDistance > 300.0 * 300.0)
        iNearest = -1;
    return iNearest;
}

void TelepToNearestAttachment(int entity, int target)
{
    int  MaxAttachment;
    char classname[32], modelname[64];
    GetEdictClassname(target, classname, sizeof(classname));
    if (StrEqual(classname, "infected", false))
        MaxAttachment = 14;
    else
    {
        GetEntPropString(target, Prop_Data, "m_ModelName", modelname, sizeof(modelname));
        g_sAttachMentMax.GetValue(modelname, MaxAttachment);
    }

    int   iNearestAttachment;
    float vPos[3], vAng[3], vAttachment[3], Distance, minDistance = 9999999.0;
    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", vPos);
    for (int i = 0; i < MaxAttachment; i++)
    {
        GetAttachment(target, i, vAttachment, vAng);
        Distance = GetVectorDistance(vPos, vAttachment, true);
        if (Distance < minDistance)
        {
            minDistance        = Distance;
            iNearestAttachment = i;
        }
    }

    GetAttachment(target, iNearestAttachment, vAttachment, vAng);
    TeleportEntity(entity, vAttachment, vAng, NULL_VECTOR);
}

void SendCoolDown_TENumber(int entity, int cooldown)
{
    float vPos[3], size = 35.0;
    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", vPos);
    vPos[2] = vPos[2] + 70.0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsSurvivor(i))
        {
            int[] clients    = new int[MaxClients];
            clients[0]       = i;
            int   count      = PrintDigitsInOrder(cooldown);
            int   divisor    = 1;
            float half_width = size * float(count) / 2.0, x_start;
            for (int j = 1; j < count; j++)
                divisor *= 10;
            for (int j = 0; j < count; j++)
            {
                if (j == 0)
                    x_start = half_width;
                float          x_end = x_start - size;
                int            digit = cooldown / divisor;
                ReturnTwoFloat fval;
                fval = CalculatePoint(i, vPos, x_start, size, 0.0, x_end, -size, 0.0);
                DrawNumber(fval.startPt, fval.endPt, digit, clients, 1, 1.0, { 255, 0, 0, 255 }, 1, 2.0, size);
                cooldown %= divisor;
                divisor /= 10;
                x_start = x_start - size - 5.0;
            }
        }
    }
}

void SendCircle_TE(int entity)
{
    float RingVec[3], vPos[3];
    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", vPos);
    AddVectors(vPos, { 0.0, 0.0, 30.0 }, RingVec);
    TE_SetupBeamRingPoint(RingVec, g_fDamageRange + g_fDamageRange, g_fDamageRange + g_fDamageRange + 10.0, g_sprite, 0, 0, 0, 0.1, 2.0, 0.0, { 255, 0, 0, 255 }, 0, 0);
    TE_SendToAll();
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

bool IsTrigger(int entity)
{
    char classname[64];
    GetEdictClassname(entity, classname, sizeof(classname));
    if (StrContains(classname, "trigger_", false) != -1)
        return true;
    return false;
}

bool IsSurvivor(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client) && GetClientTeam(client) == 2;
}
