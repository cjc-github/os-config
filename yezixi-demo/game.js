// ============================================================
// 第 3 层：游戏规则（简化玩法：叶子对战）
//
// 规则：
//   1. 洗牌后双方各 20 张。
//   2. 每回合你先出一张，AI 出它手里最强的一张。
//   3. 比点数；点数相同比门（万贯 4 > 索子 3 > 文钱 2 > 十字 1）。
//   4. 胜者赢得桌上两张牌；平局各得一张。
//   5. 20 回合后比赢牌数，多者获胜。
//
// 规则层只操作数据（数组），卡面交给 card-view.js 渲染。
// 想换玩法？只需要改 compare() 和 playCard()，其他都不动。
// ============================================================

const handEl = document.getElementById("hand");
const centerEl = document.getElementById("center");
const scoreEl = document.getElementById("score");
const logEl = document.getElementById("log");
const btnDeal = document.getElementById("btn-deal");

const state = {
  playerHand: [],
  aiHand: [],
  playerWon: [],
  aiWon: [],
  round: 0,
  streak: 0,
  busy: true,
  lastPlayer: null,
  lastAi: null,
  revealed: false
};

function shuffle(arr) {
  for (let i = arr.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    const t = arr[i];
    arr[i] = arr[j];
    arr[j] = t;
  }
  return arr;
}

// 核心比牌逻辑：点数优先，同点比门
function compare(a, b) {
  if (a.点数 !== b.点数) return a.点数 > b.点数 ? 1 : -1;
  if (a.门值 !== b.门值) return a.门值 > b.门值 ? 1 : -1;
  return 0;
}

function log(msg) {
  logEl.textContent = msg;
}

function render() {
  // 手牌
  handEl.innerHTML = "";
  for (const card of state.playerHand) {
    const el = leafCard(card, true);
    el.addEventListener("click", () => playCard(card));
    handEl.appendChild(el);
  }
  handEl.classList.toggle("busy", state.busy);

  // 对战区
  centerEl.innerHTML = "";
  if (state.lastPlayer) {
    const vs = document.createElement("div");
    vs.className = "vs";
    vs.innerHTML = "<span>你的出牌</span><span>对方出牌</span>";
    centerEl.appendChild(vs);

    const row = document.createElement("div");
    row.className = "center-cards";
    row.appendChild(leafCard(state.lastPlayer, true));
    row.appendChild(leafCard(state.lastAi, state.revealed));
    centerEl.appendChild(row);
  }

  // 计分
  scoreEl.textContent =
    "第 " + state.round + " / 20 回合　·　你赢 " + state.playerWon.length +
    " 张　·　对方赢 " + state.aiWon.length + " 张" +
    (state.streak >= 2 ? "　·　连胜 " + state.streak : "");
}

function deal() {
  const deck = shuffle(YEZIXI_CARDS.slice());
  state.playerHand = deck.slice(0, 20);
  state.aiHand = deck.slice(20);
  state.playerWon = [];
  state.aiWon = [];
  state.round = 0;
  state.streak = 0;
  state.busy = false;
  state.lastPlayer = null;
  state.lastAi = null;
  state.revealed = false;
  btnDeal.textContent = "再来一局";
  log("洗牌完成，双方各 20 张。点击手牌出牌。");
  render();
}

// AI：出自己手里最强的一张（简单但有效）
function aiPick() {
  let best = state.aiHand[0];
  for (const c of state.aiHand) {
    if (compare(c, best) > 0) best = c;
  }
  return best;
}

function playCard(card) {
  if (state.busy) return;
  state.busy = true;

  state.playerHand = state.playerHand.filter(c => c.id !== card.id);
  const ai = aiPick();
  state.aiHand = state.aiHand.filter(c => c.id !== ai.id);

  state.round++;
  state.lastPlayer = card;
  state.lastAi = ai;
  state.revealed = false;
  render();

  // 先显示对手牌背面，稍后翻牌结算
  setTimeout(function () {
    state.revealed = true;
    const res = compare(card, ai);
    const you = card.称谓 + "（" + card.门 + "·" + card.点数 + "）";
    const foe = ai.称谓 + "（" + ai.门 + "·" + ai.点数 + "）";
    let msg;

    if (res > 0) {
      state.playerWon.push(card, ai);
      state.streak++;
      msg = "✔ 你赢了这局：" + you + " 胜过 " + foe;
    } else if (res < 0) {
      state.aiWon.push(card, ai);
      state.streak = 0;
      msg = "✘ 你输了这局：" + foe + " 胜过 " + you;
    } else {
      state.playerWon.push(card);
      state.aiWon.push(ai);
      state.streak = 0;
      msg = "＝ 平局：双方都是 " + card.门 + "·" + card.点数 + "，各得一张";
    }
    log(msg);

    if (!state.playerHand.length && !state.aiHand.length) {
      const p = state.playerWon.length;
      const a = state.aiWon.length;
      log(
        "对局结束！你赢得 " + p + " 张，对方赢得 " + a + " 张。" +
        (p > a ? "🎉 你获胜！" : p < a ? "对方获胜。" : "平手。")
      );
    }

    state.busy = false;
    render();
  }, 650);
}

btnDeal.addEventListener("click", deal);

// 缩放：只改 --leaf-w 一个变量，卡面（含字号、内边距）整体等比缩放
const scaleEl = document.getElementById("scale");
scaleEl.addEventListener("input", function () {
  const w = Math.round(108 * (this.value / 100));
  document.documentElement.style.setProperty("--leaf-w", w + "px");
});

// 打开页面即开局
deal();
