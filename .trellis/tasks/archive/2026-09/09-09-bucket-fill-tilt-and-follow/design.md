# 技术设计

## 形态
SY135 独立视觉参数 surface_forward_tilt_degrees 初值 6，前方 cavity -Z。将 tan(angle)*(z_mid-z) 合入确定性 surface relief，体积反解与法线共享同一表面函数。满斗基准下降半跨度倾角高度，保留原 SURFACE_RELIEF_M 的斗口余量。实测 floor_heights、growth direction、模型合同不变。SY205 缺省 0。

## 同步与生命周期
SoilEffects 持有填料网格资源，网格节点挂到 MotionPresentation 的实际 cavity frame；局部 transform 由该表现适配器复用当前合同计算。30 Hz 土量快照不得再覆写绑定填料的世界姿态。继承相同层级与插值，消除独立姿态采样。
模型替换开始（包括候选合同校验失败）及 generation reset 时隐藏并收回填料到 SoilEffects；下一个匹配新模型的有效库存快照重绑。独立无 presentation 测试保留显式快照世界变换接口；有 presentation 但模型不匹配则隐藏。销毁 SoilEffects 时清理挂载节点。模型 GLB/pivot、坐标和关节语义已有合同，无新增机械决策 gate。

## 风险
挂载改变节点所有权与生命周期，要验证先释放模型和先释放 effects 的顺序。前倾幅度为初次可调值，视觉检查不能由自动测试代替。库存 ratio 继续映射视觉容量，不调整账本。
