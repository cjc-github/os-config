// ============================================================
// 第 1 层：卡牌数据 —— 唯一事实来源
// 加一张新卡 = 在这里加一行对象，其他什么都不用改。
// art 留空 "" 的卡，渲染时自动显示占位样式（见 card-view.js）。
// ============================================================

const CARDS = [
  {
    id: "001",
    name: "烈焰术士",
    cost: 3,
    atk: 4,
    hp: 2,
    text: "对目标造成 2 点伤害",
    art: "art/fire_mage.png",
    rarity: "rare",      // common / rare / epic / legendary
    type: "生物"
  },
  {
    id: "002",
    name: "铁甲守卫",
    cost: 2,
    atk: 1,
    hp: 4,
    text: "嘲讽：敌人必须优先攻击它",
    art: "",              // 没有插画 → 自动显示占位样式
    rarity: "common",
    type: "生物"
  },
  {
    id: "003",
    name: "寒冰箭",
    cost: 1,
    atk: 0,
    hp: 0,
    text: "冻结一个敌方单位",
    art: "art/ice_bolt.png",
    rarity: "common",
    type: "法术"
  },
  {
    id: "004",
    name: "暗影伯爵",
    cost: 5,
    atk: 5,
    hp: 5,
    text: "亡语：抽一张牌",
    art: "",
    rarity: "epic",
    type: "生物"
  },
  {
    id: "005",
    name: "治疗祷言",
    cost: 1,
    atk: 0,
    hp: 0,
    text: "恢复 4 点生命",
    art: "",
    rarity: "common",
    type: "法术"
  },
  {
    id: "006",
    name: "炎爆术",
    cost: 10,
    atk: 0,
    hp: 0,
    text: "对敌方英雄造成 10 点伤害",
    art: "",
    rarity: "legendary",
    type: "法术"
  }
];
