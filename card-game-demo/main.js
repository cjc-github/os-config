// ============================================================
// 第 3 层：游戏逻辑（这里只做演示：抽牌、选牌）
// 注意：逻辑层只操作"数据"，不直接拼卡面 —— 画面交给 card-view.js。
// 手牌存的是数据引用，不是 DOM，方便以后做洗牌/结算/存档。
// ============================================================

const handEl = document.getElementById("hand");
const infoEl = document.getElementById("info");

// 手牌：只存卡牌数据
let hand = [CARDS[0], CARDS[1], CARDS[2]];
let selectedId = null;

function renderHand() {
  handEl.innerHTML = "";
  for (const card of hand) {
    const el = createCardElement(card);
    if (card.id === selectedId) el.classList.add("selected");

    el.addEventListener("click", () => {
      selectedId = selectedId === card.id ? null : card.id;
      renderHand();
      infoEl.textContent = selectedId
        ? "已选中：" + card.name + " —— " + card.text
        : "点击一张卡进行选择";
    });

    handEl.appendChild(el);
  }
}

// 演示"动态生成卡"：从数据池随机抽一张（游戏里就是洗牌/开包）
function drawCard() {
  const pool = CARDS.filter(function (c) {
    return !hand.some(function (h) { return h.id === c.id; });
  });
  if (!pool.length) {
    infoEl.textContent = "卡池已经抽完啦，刷新页面重置";
    return;
  }
  const pick = pool[Math.floor(Math.random() * pool.length)];
  hand.push(pick);
  infoEl.textContent = "抽到了：" + pick.name;
  renderHand();
}

document.getElementById("btn-draw").addEventListener("click", drawCard);

renderHand();
