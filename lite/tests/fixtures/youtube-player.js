// Controlled player states, exercised inside the packaged Chromium browser.
window.testYouTubePlayer = async function () {
    const wait = () => new Promise(resolve => setTimeout(resolve, 160));
    const results = {};
    async function run(name, {ad = false, duration = 120, content = 120, live = false,
                              marker = '', progress = duration, skip = false, hidden = false, reuse = false} = {}) {
        document.querySelector('#movie_player')?.remove();
        const player = document.createElement('div');
        player.id = 'movie_player';
        player.className = ad ? 'html5-video-player ad-showing' : 'html5-video-player';
        const video = document.createElement('video');
        let currentTime = 11, seeks = 0, clicks = 0;
        Object.defineProperties(video, {
            duration: {get: () => duration},
            currentTime: {get: () => currentTime, set: value => { currentTime = value; seeks++; }},
            currentSrc: {get: () => `https://media.example/${name}`}
        });
        player.getPlayerResponse = () => ({videoDetails: {lengthSeconds: content, isLiveContent: live}});
        player.getStatsForNerds = () => ({debug_info: marker});
        player.getProgressState = () => ({duration: progress});
        player.seekTo = value => {currentTime = value; seeks++;};
        player.append(video);
        if (skip) {
            const button = document.createElement('button');
            button.className = 'ytp-ad-skip-button-modern';
            button.textContent = 'Skip Ad';
            button.hidden = hidden;
            button.onclick = () => { clicks++; player.classList.remove('ad-showing'); };
            player.append(button);
        }
        document.body.append(player);
        document.dispatchEvent(new Event('yt-navigate-finish'));
        await wait();
        // Repeated player events must not repeatedly seek/click the same ad.
        video.dispatchEvent(new Event('timeupdate'));
        await wait();
        if (reuse) {
            player.classList.remove('ad-showing');
            await wait();
            player.classList.add('ad-showing');
            await wait();
        }
        results[name] = {seeks, clicks, currentTime, volume: video.volume, rate: video.playbackRate};
        player.remove();
    }
    await run('content');
    await run('staleClass', {ad: true});
    await run('live', {ad: true, duration: Infinity, live: true});
    await run('unknown', {ad: true, duration: 15, content: null});
    await run('clientAd', {ad: true, duration: 15});
    await run('skip', {ad: true, skip: true});
    await run('reusedSkip', {ad: true, skip: true, reuse: true});
    await run('hiddenSkip', {ad: true, skip: true, hidden: true});
    await run('serverAd', {marker: 'SSAP, AD, fixture', progress: 15});
    await run('serverContent', {marker: 'SSAP, CONTENT, fixture', progress: 15});
    return results;
};
