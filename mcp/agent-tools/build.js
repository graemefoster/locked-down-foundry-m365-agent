// Build the MCP server into a single self-contained CommonJS bundle.
//
// The MCP App Service is network-locked (no outbound npm registry access) and deploys with
// SCM_DO_BUILD_DURING_DEPLOYMENT=false, so nothing installs dependencies on the server. We bundle
// every dependency into dist/index.js here (on the azd host, which has internet) and ship only the
// dist/ folder. At runtime the app needs nothing but `node dist/index.js` - no node_modules, no
// ts-node. history.txt is read at runtime via __dirname, so copy it next to the bundle.
const esbuild = require('esbuild');
const fs = require('fs');
const path = require('path');

const outdir = path.resolve(__dirname, 'dist');

esbuild
    .build({
        entryPoints: [path.resolve(__dirname, 'src/index.ts')],
        bundle: true,
        platform: 'node',
        target: 'node22',
        format: 'cjs',
        outfile: path.join(outdir, 'index.js'),
        logLevel: 'info',
    })
    .then(() => {
        fs.copyFileSync(path.resolve(__dirname, 'src/history.txt'), path.join(outdir, 'history.txt'));
        console.log('Bundled MCP server to dist/index.js (+ history.txt).');
    })
    .catch((err) => {
        console.error(err);
        process.exit(1);
    });
