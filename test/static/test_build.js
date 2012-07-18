/*global test, asyncTest, ok, equal, deepEqual, start, module, strictEqual, notStrictEqual, raises*/
define([
    'require',
    'a',
    'text!csi-context.json',
    'extra-components/some-component/module',
    'text!fixture.json',
    'css!style.css',
    'css!images.css',
    'css!100:extra-components/some-component/theme.css'
], function(require, a, csiJson, TestComponentModule, fixture) {

    var baseUrl = require.toUrl('test').replace(/\/test\.js$/, '') || '',
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
        var i, j, line, url, sheet, rule, pathname, lines,
            linkTags = document.head.getElementsByTagName('link'),
            request = new XMLHttpRequest();
        equal(linkTags.length, 2);
        for (i = 0; i < document.styleSheets.length; i++) {
            sheet = document.styleSheets[i];
            if (/test_build-[a-f0-9]{32}/.test(sheet.href)) {
                request.open('GET', sheet.href, false);
                request.send(null);
                lines = request.responseText.split('\n');
                for (j = 0; j < lines.length; j++) {
                    line = lines[j];
                    if (/url\((["']?)([^)]+)\1\)/i.test(line)) {
                        url = line.match(/url\((["']?)([^)]+)\1\)/i)[2];
                        equal(url[0], '/', 'urls must be absolute, css contained url: ' + url);
                    }
                }
            }
        }
    });

    // this tests that the `component build --templatepath=* --baseurl=*`
    // actually outputs a config and that it corresponds with the config
    // used by the test server
    test('baseUrl has been set', function() {
        equal(JSON.parse(csi.config).baseUrl, baseUrl);
    });


    // this is mostly just a visual test...
    test('image loading', function() {
        var i, el, classes = [
            'my-component-background-image',
            'my-component-background-image-again',
            'something-with-background-image',
            'something-else-with-background-image'
        ];
        for (i = 0; i < classes.length; i++) {
            el = document.createElement('div');
            el.className = classes[i];
            document.body.appendChild(el);
        }
        ok(true);
    });

    start();
});
