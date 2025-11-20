# Left 4 Dead 2 专用服务器 VScript 脚本污染防护机制
## Left 4 Dead 2 Dedicated Server VScript Contamination Prevention Mechanism 
 
### 功能目标 | Function Goal 
▌ **核心问题**  
防止专用服务器上运行非本地图设计的第三方脚本（脚本污染）  
▌ **典型场景**  
在地图 A 上错误地加载并运行了为地图 B 设计的脚本  
▌ **根源分析**  
问题通常源于不同地图作者在 VScript 脚本编写技能水平上的差异  
 
▌ **Core Issue**  
Prevent third-party map scripts not designed for current map from running (script contamination)  
▌ **Typical Scenario**  
Scripts for Map B are erroneously loaded and executed on Map A  
▌ **Root Cause Analysis**  
Primarily due to uneven scripting proficiency among map authors  
 
---
 
### 常见污染脚本示例 | Common Contamination Script Examples
```diff 
- director_base_addon.nut  (或类似名称)
- scriptedmode_addon.nut  (或类似名称)
- mapspawn_addon.nut  (或类似名称)
- coop.nut  (或相关合作模式脚本)
- realism.nut  (或写实模式相关脚本)
- 其他全局加载的游戏模式脚本 
