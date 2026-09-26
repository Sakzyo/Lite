// Fallback for ads that survive response filtering, including SPA player changes.
// The SSAP, AD marker is also used by uBlockOrigin/uAssets quick-fixes.txt.
(() => {
    if (window.__liteYouTubeAds) {
        window.__liteYouTubeAds.setEnabled(true);
        return;
    }
    let enabled = false, timer = 0;
    let sought = new WeakMap(), clicked = new WeakMap();
    const observer = new MutationObserver(schedule);
    const events = ['loadedmetadata', 'durationchange', 'playing', 'timeupdate', 'yt-navigate-finish'];
    function schedule() {
        if (enabled && !timer) timer = setTimeout(check, 40);
    }
    function check() {
        timer = 0;
        if (!enabled) return;
        for (const player of document.querySelectorAll('#movie_player, .html5-video-player')) {
            const video = player.querySelector('video');
            if (!video) continue;
            try {
                const serverAd = player.getStatsForNerds?.()?.debug_info?.startsWith('SSAP, AD') === true;
                const ad = serverAd || player.classList.contains('ad-showing') ||
                    player.classList.contains('ad-interrupting');
                if (!ad) { sought.delete(video); clicked.delete(video); continue; }
                const skip = [...player.querySelectorAll(
                    '.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button'
                )].find(button => !button.disabled && button.getClientRects().length &&
                    getComputedStyle(button).visibility === 'visible');
                if (skip && clicked.get(video) !== skip) {
                    clicked.set(video, skip);
                    skip.click();
                    continue;
                }
                const details = player.getPlayerResponse?.()?.videoDetails;
                if (details?.isLive || details?.isLiveContent) continue;
                const duration = serverAd ? player.getProgressState?.()?.duration : video.duration;
                if (!Number.isFinite(duration) || duration <= 0) continue;
                // A stale ad class must never seek the main video to its end.
                // Without an explicit server-ad marker, require distinct ad media.
                const contentDuration = Number(details?.lengthSeconds);
                if (!serverAd && (!Number.isFinite(contentDuration) || contentDuration <= 0 ||
                    Math.abs(contentDuration - duration) < 1)) continue;
                const key = `${video.currentSrc}|${duration}|${serverAd}`;
                if (sought.get(video) === key) continue;
                if (serverAd) {
                    if (typeof player.seekTo !== 'function') continue;
                    player.seekTo(duration);
                } else {
                    video.currentTime = duration;
                }
                sought.set(video, key);
            } catch (_) {
                // Players may be replaced while a SPA navigation is in flight.
            }
        }
    }
    function setEnabled(value) {
        if (enabled === value) return;
        enabled = value;
        if (enabled) {
            observer.observe(document, {subtree: true, childList: true, attributes: true, attributeFilter: ['class']});
            for (const event of events) document.addEventListener(event, schedule, true);
            schedule();
        } else {
            observer.disconnect();
            for (const event of events) document.removeEventListener(event, schedule, true);
            clearTimeout(timer);
            timer = 0;
            sought = new WeakMap();
            clicked = new WeakMap();
        }
    }
    window.__liteYouTubeAds = {setEnabled};
    addEventListener('pageshow', schedule);
    setEnabled(true);
})();
