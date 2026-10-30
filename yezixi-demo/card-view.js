// ============================================================
// 第 2 层：叶子卡渲染组件 —— 输入数据，输出竖长"叶子"形卡面
// 版面：顶部(门/点数) + 绣像区 + 头衔 + 名号 + 底部(门·点数)
// 绣像区优先用 art 图片；没有图片时显示"名号首字"印章（纯文本，四门配色）
// ============================================================

function sealHTML(card) {
  return '<div class="leaf-seal">' + card.名号.charAt(0) + "</div>";
}

function leafCard(card, faceUp) {
  const el = document.createElement("div");

  if (faceUp && card) {
    el.className = "leaf-card door-" + card.门;
    el.dataset.id = card.id;

    const art = card.art
      ? '<div class="leaf-art-wrap"><img class="leaf-art" src="' + card.art +
        '" alt="' + card.名号 + '"></div>'
      : sealHTML(card);

    el.innerHTML =
      '<div class="leaf-top">' +
      '<span class="leaf-door-badge">' + card.门 + "</span>" +
      '<span class="leaf-point">' + card.点数 + "</span>" +
      "</div>" +
      art +
      '<div class="leaf-honor">' + card.称谓 + "</div>" +
      '<div class="leaf-name">' + card.名号 + "</div>" +
      '<div class="leaf-foot">' + card.门 + " · " + card.点数 + "</div>";

    // 插画加载失败 → 自动退回印章（图片只是可选素材）
    const img = el.querySelector("img.leaf-art");
    if (img) {
      img.addEventListener("error", function () {
        img.parentNode.outerHTML = sealHTML(card);
      });
    }
  } else {
    el.className = "leaf-card face-down";
    el.innerHTML =
      '<div class="leaf-back-char">葉</div>' +
      '<div class="leaf-back-txt">叶子戏</div>';
  }

  return el;
}
