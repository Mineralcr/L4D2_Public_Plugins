#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <dhooks>

#define GAMEDATA         "l4d2_ignore_airwall"
#define GAMEDATA_VERSION 35

methodmap GameDataWrapper < GameData
{

    public GameDataWrapper(const char[] file)
    {
        GameData gd = new GameData(file);
        if (!gd) SetFailState("[GameData] Missing gamedata of file \"%s\".", file);
        return view_as<GameDataWrapper>(gd);
    }

    public DynamicDetour CreateDetourOrFail(const char[] name,
                                     bool          bNow     = true,
                                     DHookCallback preHook  = INVALID_FUNCTION,
                                     DHookCallback postHook = INVALID_FUNCTION)
    {
        DynamicDetour hSetup = DynamicDetour.FromConf(this, name);

        if (!hSetup)
            SetFailState("[Detour] Missing detour setup section \"%s\".", name);

        if (bNow)
        {
            if (preHook != INVALID_FUNCTION && !hSetup.Enable(Hook_Pre, preHook))
                SetFailState("[Detour] Failed to pre-detour of section \"%s\".", name);

            if (postHook != INVALID_FUNCTION && !hSetup.Enable(Hook_Post, postHook))
                SetFailState("[Detour] Failed to post-detour of section \"%s\".", name);
        }

        return hSetup;
    }
}

int
    g_iPlugins,
    g_iMaskMode[MAXPLAYERS + 1],
    g_iCTerrorGameGGMovement[2];

ConVar
    g_hCvar_AirWall;

public Plugin myinfo =
{
    name        = "l4d2_ignore_airwall",
    author      = "洛琪",
    description = "无视空气墙插件",
    version     = "1.0",
    url         = "https://steamcommunity.com/profiles/76561198812009299/"
};

public void OnPluginStart()
{
    g_hCvar_AirWall = CreateConVar("l4d2_mask", "1", "开启或关闭本插件", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_hCvar_AirWall.AddChangeHook(OnCvarChnaged);
    RegConsoleCmd("sm_mask", cmdMask);
    InItGameData();

    AutoExecConfig(true, "l4d2_ignore_airwall");
}

void GetCvars()
{
    g_iPlugins = g_hCvar_AirWall.IntValue;
    if (g_iPlugins == 0)
    {
        for (int i = 0; i < MAXPLAYERS + 1; i++)
            g_iMaskMode[i] = 0;
    }
}

void OnCvarChnaged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    GetCvars();
}

public void OnConfigsExecuted()
{
    GetCvars();
}

Action cmdMask(int client, int args)
{
    if (!client || !IsClientInGame(client) || IsFakeClient(client))
        return Plugin_Handled;

    if (g_iPlugins == 0)
    {
        PrintToChat(client, "空气墙插件当前已关闭.");
        return Plugin_Handled;
    }

    Mask(client);
    return Plugin_Handled;
}

void Mask(int client)
{
    char info[12];
    char disp[MAX_NAME_LENGTH];
    Menu menu = new Menu(Mask_MenuHandler);
    menu.SetTitle("空气墙碰撞插件:");
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && GetClientTeam(i) == 2)
        {
            FormatEx(info, sizeof info, "%d", GetClientUserId(i));
            FormatEx(disp, sizeof disp, "[%s] - %N", g_iMaskMode[i] == 0 ? "●" : g_iMaskMode[i] == 1 ? "○" : "  ", i);
            menu.AddItem(info, disp);
        }
    }
    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

int Mask_MenuHandler(Menu menu, MenuAction action, int client, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            char item[12];
            menu.GetItem(param2, item, sizeof item);
            int target = GetClientOfUserId(StringToInt(item));
            if (target && IsClientInGame(target))
            {
                if (target != client && !HasAccess(client, "c"))
                {
                    PrintToChat(client, "非管理玩家无权修改其他人碰撞.");
                    return 0;
                }
                g_iMaskMode[target] = g_iMaskMode[target] + 1;
                if (g_iMaskMode[target] > 2)
                    g_iMaskMode[target] = 0;

                char buffer[64];
                switch (g_iMaskMode[target])
                {
                    case 0: FormatEx(buffer, sizeof(buffer), "\x04已启用 \x05%N \x01和空气墙的碰撞", target);
                    case 1: FormatEx(buffer, sizeof(buffer), "\x04已关闭 \x05%N \x01和玩家空气墙的碰撞", target);
                    case 2: FormatEx(buffer, sizeof(buffer), "\x04已关闭 \x05%N \x01和全部空气墙的碰撞", target);
                }
                SimplePrint(client, target, buffer);
                Mask(client);
            }
            else
                PrintToChat(client, "目标玩家已失效");
        }

        case MenuAction_End:
            delete menu;
    }

    return 0;
}

void SimplePrint(int client, int target, char[] buffer)
{
    PrintToChat(target, buffer);
    if (target != client)
        PrintToChat(client, buffer);
}

bool HasAccess(int client, char[] g_sAcclvl)
{
    if (strlen(g_sAcclvl) == 0)
        return true;

    else if (StrEqual(g_sAcclvl, "-1"))
        return false;

    int flag = GetUserFlagBits(client);
    if (flag & ReadFlagString(g_sAcclvl) || flag & ADMFLAG_ROOT)
    {
        return true;
    }

    return false;
}

MRESReturn DTR_CTerrorPlayer_PlayerSolidMask_Post(int pThis, DHookReturn hReturn)
{
    switch (g_iMaskMode[pThis])
    {
        case 0: return MRES_Ignored;
        case 1: hReturn.Value = MASK_NPCSOLID;
        case 2: hReturn.Value = MASK_SHOT_HULL;
    }
    return MRES_Override;
}

MRESReturn DTR_CBaseEntity_GetTeamNumber_Pre(int pThis, DHookReturn hReturn)
{
    if (g_iCTerrorGameGGMovement[0] == 1)
        g_iCTerrorGameGGMovement[1] = pThis;
    return MRES_Ignored;
}

MRESReturn DTR_CTerrorGameGGMovement_PlayerSolidMask_Post(int pThis, DHookReturn hReturn, DHookParam hParms)
{
    g_iCTerrorGameGGMovement[0] = 0;
    switch (g_iMaskMode[g_iCTerrorGameGGMovement[1]])
    {
        case 0: return MRES_Ignored;
        case 1: hReturn.Value = MASK_NPCSOLID;
        case 2: hReturn.Value = MASK_SHOT_HULL;
    }
    return MRES_Override;
}

MRESReturn DTR_CTerrorGameGGMovement_PlayerSolidMask_Pre(int pThis, DHookReturn hReturn, DHookParam hParms)
{
    g_iCTerrorGameGGMovement[0] = 1;
    return MRES_Ignored;
}

void InItGameData()
{
    CheckGameDataFile();

    GameDataWrapper gd = new GameDataWrapper(GAMEDATA);
    delete gd.CreateDetourOrFail("CTerrorPlayer::PlayerSolidMask", true, _, DTR_CTerrorPlayer_PlayerSolidMask_Post);
    delete gd.CreateDetourOrFail("CTerrorGameGGMovement::PlayerSolidMask", true, DTR_CTerrorGameGGMovement_PlayerSolidMask_Pre, DTR_CTerrorGameGGMovement_PlayerSolidMask_Post);
    delete gd.CreateDetourOrFail("CBaseEntity::GetTeamNumber", true, DTR_CBaseEntity_GetTeamNumber_Pre);

    delete gd;
}

void CheckGameDataFile()
{
    char sPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sPath, sizeof(sPath), "gamedata/%s.txt", GAMEDATA);
    File hFile;
    bool bNeedUpdate = false, bNull = true;
    if (FileExists(sPath))
    {
        bNull = false;
        char buffer1[64], buffer2[64];
        hFile = OpenFile(sPath, "r", false);
        hFile.ReadLine(buffer1, sizeof(buffer1));
        FormatEx(buffer2, sizeof(buffer2), "//%d\n", GAMEDATA_VERSION);
        if (!StrEqual(buffer1, buffer2, false))
            bNeedUpdate = true;
    }
    else
    {
        bNeedUpdate = true;
    }

    if (bNeedUpdate)
    {
        hFile = OpenFile(sPath, "w", false);
        hFile.WriteLine("//%d", GAMEDATA_VERSION);
        hFile.WriteLine("\"Games\"");
        hFile.WriteLine("{");
        hFile.WriteLine("	\"left4dead2\"");
        hFile.WriteLine("	{");
        hFile.WriteLine("		\"Functions\"");
        hFile.WriteLine("		{");
        hFile.WriteLine("			\"CBaseEntity::GetTeamNumber\"");
        hFile.WriteLine("			{");
        hFile.WriteLine("				\"signature\"		\"CBaseEntity::GetTeamNumber\"");
        hFile.WriteLine("				\"callconv\"		\"thiscall\"");
        hFile.WriteLine("				\"return\"		    \"int\"");
        hFile.WriteLine("				\"this\"		    \"entity\"");
        hFile.WriteLine("			}");
        hFile.WriteLine("");
        hFile.WriteLine("			\"CTerrorPlayer::PlayerSolidMask\"");
        hFile.WriteLine("			{");
        hFile.WriteLine("				\"signature\"		\"CTerrorPlayer::PlayerSolidMask\"");
        hFile.WriteLine("				\"callconv\"		\"thiscall\"");
        hFile.WriteLine("				\"return\"		    \"int\"");
        hFile.WriteLine("				\"this\"		    \"entity\"");
        hFile.WriteLine("				\"arguments\"");
        hFile.WriteLine("				  {");
        hFile.WriteLine("				     \"brushonly\"");
        hFile.WriteLine("				      {");
        hFile.WriteLine("		                \"type\"	    \"bool\"");
        hFile.WriteLine("			          }");
        hFile.WriteLine("			      }");
        hFile.WriteLine("			}");
        hFile.WriteLine("");
        hFile.WriteLine("			\"CTerrorGameGGMovement::PlayerSolidMask\"");
        hFile.WriteLine("			{");
        hFile.WriteLine("				\"signature\"		\"CTerrorGameGGMovement::PlayerSolidMask\"");
        hFile.WriteLine("				\"callconv\"		\"thiscall\"");
        hFile.WriteLine("				\"return\"		    \"int\"");
        hFile.WriteLine("				\"this\"		    \"address\"");
        hFile.WriteLine("				\"arguments\"");
        hFile.WriteLine("				  {");
        hFile.WriteLine("				     \"brushonly\"");
        hFile.WriteLine("				      {");
        hFile.WriteLine("		                \"type\"	    \"bool\"");
        hFile.WriteLine("			          }");
        hFile.WriteLine("				     \"player\"");
        hFile.WriteLine("				      {");
        hFile.WriteLine("		                \"type\"	    \"cbaseentity\"");
        hFile.WriteLine("			          }");
        hFile.WriteLine("			      }");
        hFile.WriteLine("			}");
        hFile.WriteLine("		}");
        hFile.WriteLine("");
        hFile.WriteLine("		\"Signatures\"");
        hFile.WriteLine("		{");
        hFile.WriteLine("		       \"CBaseEntity::GetTeamNumber\"");
        hFile.WriteLine("		         {");
        hFile.WriteLine("		               \"library\"	    \"server\"");
        hFile.WriteLine("		               \"linux\"	    \"@_ZNK11CBaseEntity13GetTeamNumberEv\"");
        hFile.WriteLine("		               \"windows\"	    \"\\x8B\\x81\\x38\\x02\\x00\\x00\\xC3\"");
        hFile.WriteLine("			     }");
        hFile.WriteLine("		       \"CTerrorPlayer::PlayerSolidMask\"");
        hFile.WriteLine("		         {");
        hFile.WriteLine("		               \"library\"	    \"server\"");
        hFile.WriteLine("		               \"linux\"	    \"@_ZNK13CTerrorPlayer15PlayerSolidMaskEb\"");
        hFile.WriteLine("		               \"windows\"	    \"\\x55\\x8B\\xEC\\x53\\x56\\x8B\\xF1\\xE8\\x2A\\x2A\\x2A\\x2A\"");
        hFile.WriteLine("			     }");
        hFile.WriteLine("		       \"CTerrorGameGGMovement::PlayerSolidMask\"");
        hFile.WriteLine("		         {");
        hFile.WriteLine("		               \"library\"	    \"server\"");
        hFile.WriteLine("		               \"linux\"	    \"@_ZNK19CTerrorGameMovement15PlayerSolidMaskEbP11CBasePlayer\"");
        hFile.WriteLine("		               \"windows\"	    \"\\x55\\x8B\\xEC\\x53\\x56\\x8B\\x75\\x0C\\x57\\x33\\xFF\"");
        hFile.WriteLine("			     }");
        hFile.WriteLine("	    }");
        hFile.WriteLine("	}");
        hFile.WriteLine("}");

        if(!bNull)
        {
            char buffer[64];
            do
            {
                hFile.WriteLine("");
            }
            while (hFile.ReadLine(buffer, sizeof(buffer)));
        }
        FlushFile(hFile);
    }

    delete hFile;
}
