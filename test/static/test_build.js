/*global test, asyncTest, ok, equal, deepEqual, start, module, strictEqual, notStrictEqual, raises*/
define([
    'a',
    'text!csi-context.json',
    'extra-components/some-component/module',
    'text!fixture.json',
    'css!style.css',
    'css!images.css',
    'css!100:extra-components/some-component/theme.css'
], function(a, csiJson, TestComponentModule, fixture) {

    var baseUrl = '/' + document.getElementsByTagName('script')[0].src
        .replace(/^http:\/\/[a-zA-Z0-9\-._]+(:\d+)\//, '')
        .replace(/\/test_build.js$/, ''),

    csi = window.csi = JSON.parse(csiJson);

    test('require works', function() {
        ok(a);
        equal(a.name, 'a');
    });

    test('path plugin works', function() {
        ok(TestComponentModule);
        TestComponentModule();
    });

    test('text plugin works', function() {
        ok(fixture);
        equal(JSON.parse(fixture).foo, 'bar');
    });

    asyncTest('including style works', function() {
        var color, el = document.createElement('div');
        document.getElementById('qunit-fixture').appendChild(el);
        document.body.style.visibility = 'hidden';
        setTimeout(function() {
            document.body.style.visibility = '';
            setTimeout(function() {
                color = getComputedStyle(el, null).getPropertyValue('color');
                equal(color, 'rgb(0, 0, 0)');
                el.className = 'colorized';
                color = getComputedStyle(el, null).getPropertyValue('color');
                equal(color, 'rgb(255, 0, 0)');
                start();
            }, 50);
        }, 50);
    });

    test('css ordering works', function() {
        var color, el = document.createElement('div');
        document.getElementById('qunit-fixture').appendChild(el);
        color = getComputedStyle(el, null).getPropertyValue('background-color');
        ok(/rgba?\(0, 0, 0/.test(color));
        el.className = 'my-overridden-style';
        color = getComputedStyle(el, null).getPropertyValue('background-color');
        ok(/rgba?\(0, \d{2,3}, 0/.test(color));
    });

    test('css paths re-written correctly', function() {
        var i, j, len, tag, line, url, rewritten, beforeRewrite,
            styleTags = document.getElementsByTagName('style');
        equal(styleTags.length, 4);
        for (i = 0; i < styleTags.length; i++) {
            tag = styleTags[i];
            for (j = 0; j < tag.innerHTML.split('\n').length; j++) {
                line = tag.innerHTML.split('\n')[j];
                if (/url\((["']?)([^)]+)\1\)/i.test(line)) {
                    url = line.match(/url\((["']?)([^)]+)\1\)/i)[2];
                    equal(url[0], '/', 'all URLs are absolute');
                }
            }
            if (/my-component/.test(tag.innerHTML)) {
                rewritten = baseUrl + '/extra-components/some-component/background.png';
                beforeRewrite = "url('background.png')";
                ok(tag.innerHTML.indexOf(rewritten) >= 0);
                ok(tag.innerHTML.indexOf(beforeRewrite) === -1);
            }
        }
    });

    // this tests that the `component build --templatepath=* --baseurl=*`
    // actually outputs a config and that it corresponds with the config
    // used by the test server
    test('baseUrl has been set', function() {
        equal(JSON.parse(csi.config).baseUrl, baseUrl);
    });

    start();
});
