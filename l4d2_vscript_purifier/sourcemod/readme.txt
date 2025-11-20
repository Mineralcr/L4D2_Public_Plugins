# Left 4 Dead 2 专用服务器 VScript 防污染机制  
*(Dedicated Server VScript Anti-Contamination Mechanism for Left 4 Dead 2)*
 
---
 
## 🎯 功能 / Function 
### 核心目标  
**防止在专用服务器上加载地图时出现第三方地图脚本污染问题**  
*Core Objective: Prevent third-party map script contamination issues when loading maps on dedicated servers.*
 
---
 
## ❓ 问题描述  
**当游玩地图 A 时，错误地加载并执行了地图 B 的脚本**  
这通常源于不同地图作者在脚本编写能力和规范遵循上的差异。  
*Problem Description: When playing Map A, scripts intended for Map B are erroneously loaded and executed. This typically stems from varying levels of scripting proficiency and adherence to standards among map authors.*
 
---
 
## ⚠️ 常见污染脚本示例  
- `director_base_addon.nut`   
- `scriptedmode_addon.nut`   
- `mapspawn_addon.nut`   
- `coop.nut`   
- `realism.nut`   
*(及其他设计为全局加载的脚本)*  
*Common Contamination Script Examples: director_base_addon.nut,  scriptedmode_addon.nut,  mapspawn_addon.nut,  coop.nut,  realism.nut,  and many other scripts designed to load globally.*
 
---
 
## 📌 注意事项 / Important Notes
### 🔍 识别受控脚本  
**只有与地图的 mission 文件（如 `a1_intro_mall.nut` ）打包在同一个 VPK 文件内的脚本**，才会被识别为地图脚本并受限加载。  
*Identifying Controlled Scripts: Only script files packaged within the same VPK file as the map's mission file are identified as map scripts and subjected to loading restrictions.*
 
### ✅ 豁免脚本  
**位于 VPK 文件之外的脚本**（如直接置于 `scripts/vscripts/` 目录下的脚本）被视为普通脚本模组，**不会被阻止加载**。  
*Exempted Scripts: Scripts located outside VPK files (e.g., in `scripts/vscripts/`) are treated as regular script-type mods, and their loading is NOT prevented.*
 
---
 
## ⚙️ 白名单机制 / Whitelist Mechanism
### 🔄 自动生成  
插件在首次成功运行后自动生成两个白名单配置文件。  
*Automatic Generation: The plugin generates two whitelist configuration files upon successful first run.*
 
### 📜 模式脚本白名单  
- **文件路径**: `cfg/configs/l4d2_vscript_mode_whitelist.cfg`   
- **作用**: 此名单中的游戏模式脚本（如 `coop`, `versus`, `survival`）将被放行加载。  
*File Path: `cfg/configs/l4d2_vscript_mode_whitelist.cfg`*   
*Purpose: Game mode scripts (e.g., coop, versus, survival) listed here will be allowed to load.*
 
### 📦 VPK 文件白名单  
- **文件路径**: `cfg/configs/l4d2_vscript_vpk_whitelist.cfg`   
- **作用**: 此名单中列出的 VPK 文件内所有脚本均被放行加载。  
*File Path: `cfg/configs/l4d2_vscript_vpk_whitelist.cfg`*   
*Purpose: All scripts within the VPK files listed here will be allowed to load.* 
