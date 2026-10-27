"use strict";

// Open a linked answer before the browser scrolls to it.
function openLinkedAnswer() {
  const answer = document.getElementById(location.hash.slice(1));
  if (answer instanceof HTMLDetailsElement) answer.open = true;
}
window.addEventListener("hashchange", openLinkedAnswer);
openLinkedAnswer();

// Preview releases are excluded from GitHub's /releases/latest endpoint.
// Keep the working HTML download if the API is unavailable or rate limited.
async function updateMacDownloads() {
  try {
    const response = await fetch("https://api.github.com/repos/iteufel/nocturne/releases?per_page=100");
    if (!response.ok) return;
    const releases = await response.json();
    const latest = releases
      .filter(release => !release.draft)
      .sort((a, b) => Date.parse(b.published_at) - Date.parse(a.published_at))
      .flatMap(release => release.assets)
      .find(asset => ["Nocturne-macOS-arm64.zip", "Nocturne-Server-macOS-arm64.zip"].includes(asset.name) && asset.state === "uploaded");
    if (!latest) return;
    const url = new URL(latest.browser_download_url);
    if (url.origin !== "https://github.com" || !url.pathname.startsWith("/iteufel/nocturne/releases/download/")) return;
    document.querySelectorAll("[data-mac-download]").forEach(link => {
      link.href = url.href;
    });
  } catch {
    // The pinned release remains directly downloadable without JavaScript.
  }
}
updateMacDownloads();
