#!/usr/bin/env node

var path = require('path'),
    coffeescript = require('coffee-script'),
    srcPath = path.join(__dirname, '../csi'),
    csi = require(srcPath);

csi.run();
