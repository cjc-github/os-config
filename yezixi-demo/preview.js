// ============================================================
// 缩放预览页逻辑
// 复用 data.js + card-view.js，仅演示 --leaf-w 变化的效果
// ============================================================

// 用"鲁智深"做样板牌（万贯门，印章字明显）
const sampleCard =
  YEZIXI_CARDS.find(function (c) { return c.名号 === "鲁智深"; }) || YEZIXI_CARDS[0];

const BASE_W = 108; // 100% 时的卡宽

function cardHolder(card) {
  const holder = document.createElement("div");
  holder.appendChild(leafCard(card, true));
  return holder;
}

// 1. 同一张牌在不同尺寸
const SIZES = [70, 85, 100, 120, 140];
const sizeRow = document.getElementById("size-row");
SIZES.forEach(function (pct) {
  const w = Math.round(BASE_W * pct / 100);
  const box = document.createElement("div");
  box.className = "size-box";
  box.style.setProperty("--leaf-w", w + "px");

  const label = document.createElement("div");
  label.className = "size-label";
  label.textContent = pct + "% · 卡宽 " + w + "px · 基准字号 " + (w * 0.1111).toFixed(1) + "px";

  box.appendChild(label);
  box.appendChild(cardHolder(sampleCard));
  sizeRow.appendChild(box);
});

// 2. 四门配色（标准尺寸）
const doorRow = document.getElementById("door-row");
["万贯", "索子", "文钱", "十字"].forEach(function (door) {
  const card = YEZIXI_CARDS.find(function (c) { return c.门 === door; });
  const box = document.createElement("div");
  box.className = "size-box";

  const label = document.createElement("div");
  label.className = "size-label";
  label.textContent = door + " · " + card.名号 + " " + card.点数;

  box.appendChild(label);
  box.appendChild(cardHolder(card));
  doorRow.appendChild(box);
});

// 3. 手牌条：小 / 大 对比
function fillHand(el, count) {
  el.innerHTML = "";
  for (let i = 0; i < count; i++) {
    el.appendChild(leafCard(YEZIXI_CARDS[i], true));
  }
}
fillHand(document.getElementById("hand-small"), 8);
fillHand(document.getElementById("hand-large"), 8);

// 4. 拖动实时缩放
const liveEl = document.getElementById("live-card");
const liveInfo = document.getElementById("live-info");
const liveInput = document.getElementById("live-scale");
liveEl.appendChild(leafCard(sampleCard, true));

function updateLive() {
  const pct = Number(liveInput.value);
  const w = Math.round(BASE_W * pct / 100);
  liveEl.style.setProperty("--leaf-w", w + "px");
  liveInfo.textContent =
    pct + "% · 卡宽 " + w + "px · 基准字号 " + (w * 0.1111).toFixed(1) + "px";
}
liveInput.addEventListener("input", updateLive);
updateLive();
