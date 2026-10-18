"use strict";

// Open a linked answer before the browser scrolls to it.
function openLinkedAnswer() {
  const answer = document.getElementById(location.hash.slice(1));
  if (answer instanceof HTMLDetailsElement) answer.open = true;
}
window.addEventListener("hashchange", openLinkedAnswer);
openLinkedAnswer();
