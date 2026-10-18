"use strict";

const tabs = [...document.querySelectorAll('[role="tab"]')];
const descriptions = {
  "tab-desktop": "Your full Mac desktop. A natural fit for your iPad.",
  "tab-terminal": "Multiple tabs. Real shells. Right where you left them.",
  "tab-files": "Your shared Mac folder. Just a few taps away."
};

function selectTab(selectedTab) {
  tabs.forEach((tab) => {
    const selected = tab === selectedTab;
    tab.setAttribute("aria-selected", String(selected));
    tab.tabIndex = selected ? 0 : -1;
    document.getElementById(tab.getAttribute("aria-controls")).hidden = !selected;
  });
  document.querySelector(".preview-description").textContent = descriptions[selectedTab.id];
}

tabs.forEach((tab, index) => {
  tab.addEventListener("click", () => selectTab(tab));
  tab.addEventListener("keydown", (event) => {
    let nextIndex;
    if (event.key === "ArrowRight") nextIndex = (index + 1) % tabs.length;
    else if (event.key === "ArrowLeft") nextIndex = (index + tabs.length - 1) % tabs.length;
    else if (event.key === "Home") nextIndex = 0;
    else if (event.key === "End") nextIndex = tabs.length - 1;
    else return;
    event.preventDefault();
    selectTab(tabs[nextIndex]);
    tabs[nextIndex].focus({ preventScroll: true });
  });
});

// Open a linked answer before the browser scrolls to it.
function openLinkedAnswer() {
  const answer = document.getElementById(location.hash.slice(1));
  if (answer instanceof HTMLDetailsElement) answer.open = true;
}
window.addEventListener("hashchange", openLinkedAnswer);
openLinkedAnswer();
