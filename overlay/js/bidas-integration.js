/*
 * bidas-integration.js
 *
 * Injected into every page by the front proxy (nginx sub_filter), so the
 * upstream git checkout in ./web stays untouched and `git pull`-able.
 *
 * Structure only - all styling lives in overlay/css/bidas_style.css, which
 * shadows the upstream stylesheet every page already links to.
 *
 * Restructures the left-hand menu into two groups: the pages that describe the
 * repository, and the pages that get you into it. Every page carries the same
 * plain upstream menu in its markup and this script does the grouping, so
 * there is one place to change it and no copy to keep in sync.
 *
 *   Home                        <- what the repository is
 *   NGS Data
 *   Demographic Data
 *   About this Site
 *
 *   ┌ ACCESS DATA ──────────┐
 *   │ Sign In to Repository  │   <- how to get at it, kept well clear
 *   │ How to Download        │      of the descriptive pages above
 *   │   command line tool    │
 *   │ How to Upload          │
 *   │   admin only           │
 *   └────────────────────────┘
 */
(function () {
    'use strict';

    var CONSOLE_HREF = '/minio/';


    function buildRow(item) {
        var row = document.createElement('div');
        row.className = 'row' + (item.primary ? ' bidas-primary' : '');

        var col = document.createElement('div');
        col.className = 'col btm-bordered';

        var a = document.createElement('a');
        a.href = item.href;
        a.textContent = item.label;
        if (item.external) {
            a.target = '_blank';
            a.rel = 'noopener';
            a.className = 'bidas-ext';
        }

        col.appendChild(a);
        row.appendChild(col);
        return row;
    }

    /* A small second line under a menu label: "command line tool",
       "admin only". Kept out of the label itself so it stays legible at the
       sidebar's fixed width instead of being clipped. */
    function addNote(row, text) {
        if (!row) { return; }
        var a = row.querySelector('a');
        if (!a || a.querySelector('.bidas-note')) { return; }
        var note = document.createElement('span');
        note.className = 'bidas-note';
        note.textContent = text;
        a.appendChild(note);
    }

    function headingRow(text) {
        var row = document.createElement('div');
        row.className = 'row bidas-access-heading';
        var col = document.createElement('div');
        col.className = 'col';
        col.textContent = text;
        row.appendChild(col);
        return row;
    }

    /** The .row wrapping the menu link whose href ends in `name`, if present. */
    function rowFor(menu, name) {
        var links = menu.querySelectorAll('a[href]');
        for (var i = 0; i < links.length; i++) {
            var href = links[i].getAttribute('href').replace(/^\//, '');
            if (href === name) {
                var node = links[i];
                while (node && node !== menu) {
                    if (node.className && node.className.indexOf('row') === 0) { return node; }
                    node = node.parentNode;
                }
            }
        }
        return null;
    }

    function buildAccessSection(menu) {
        var section = document.createElement('div');
        section.className = 'bidas-access';
        section.setAttribute('data-bidas-access', '');

        section.appendChild(headingRow('Access Data'));
        section.appendChild(buildRow({
            href: CONSOLE_HREF,
            label: 'Sign In to Repository',
            external: true,
            primary: true
        }));

        // Reuse the upstream "How to Download" row if it is there, so its own
        // markup and any styling on it survive; otherwise make one.
        var download = rowFor(menu, 'manual.html') ||
                       buildRow({ href: 'manual.html', label: 'How to Download' });
        addNote(download, 'command line tool');
        section.appendChild(download);

        var upload = rowFor(menu, 'upload.html') ||
                     buildRow({ href: 'upload.html', label: 'How to Upload' });
        addNote(upload, 'admin only');
        section.appendChild(upload);

        // Always last, below everything else including "About this Site":
        // a separate panel rather than another run of menu entries.
        menu.appendChild(section);
    }

    // Marks the entry for the page you are on. The stylesheet owns how that
    // looks; this only sets the hook.
    function highlightCurrent(menu) {
        var here = window.location.pathname.split('/').pop() || 'index.html';
        var links = menu.querySelectorAll('a[href]');
        for (var i = 0; i < links.length; i++) {
            if (links[i].getAttribute('href').replace(/^\//, '') === here) {
                links[i].className += (links[i].className ? ' ' : '') + 'bidas-current';
            }
        }
    }

    function init() {
        var menu = document.getElementById('menu');
        if (!menu || menu.querySelector('[data-bidas-access]')) { return; }

        buildAccessSection(menu);
        highlightCurrent(menu);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
