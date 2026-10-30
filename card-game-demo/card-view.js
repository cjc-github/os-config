// ============================================================
// 第 2 层：卡牌渲染组件 —— 输入数据，输出卡面
// 整个游戏只有这一个"画卡"的地方。
// 版面固定：顶部(费用/名称/类型) + 插画 + 效果文字 + 数值
// 图片只出现在插画区，其余全是文本，天然支持多语言和动态卡。
// ============================================================

// 没有插画时的占位内容（色块 + 图标，之后随时换真图）
function placeholderFor(card) {
  const icons = { "生物": "🐉", "法术": "✨" };
  return (
    '<div class="card-art-placeholder">' +
    '<span class="big">' + (icons[card.type] || "🃏") + "</span>" +
    "<span>暂无插画<br>放一张图到 art/ 即可</span>" +
    "</div>"
  );
}

function createCardElement(card) {
  const el = document.createElement("div");
  el.className = "card rarity-" + card.rarity;
  el.dataset.id = card.id;

  // 顶部：费用 / 名称 / 类型
  const top =
    '<div class="card-top">' +
    '<span class="card-cost">' + card.cost + "</span>" +
    '<span class="card-name">' + card.name + "</span>" +
    '<span class="card-type">' + card.type + "</span>" +
    "</div>";

  // 中部：插画（唯一用图片的地方）；没有图片则用占位
  const art = card.art
    ? '<div class="card-art"><img class="card-art-img" src="' + card.art + '" alt="' + card.name + '"></div>'
    : placeholderFor(card);

  // 下部：效果文字
  const text = card.text
    ? '<div class="card-text">' + card.text + "</div>"
    : "";

  // 数值：只有生物显示攻击/生命
  const stats =
    card.atk > 0 || card.hp > 0
      ? '<div class="card-bottom"><span class="card-atk">' + card.atk +
        '</span><span class="card-hp">' + card.hp + "</span></div>"
      : "";

  el.innerHTML = top + art + text + stats;

  // 图片加载失败 → 自动换成占位样式（插画只是可选素材，缺了不崩）
  const img = el.querySelector("img.card-art-img");
  if (img) {
    img.addEventListener("error", () => {
      img.parentNode.outerHTML = placeholderFor(card);
    });
  }

  return el;
}
