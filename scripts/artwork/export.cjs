// Export the selected vector directly, preserving filters and alpha. Quick Look
// thumbnails flatten transparent icon margins to white and must not be used here.
const fs = require('node:fs');
const path = require('node:path');
const { Resvg } = require('@resvg/resvg-js');
const [requestedSource, output] = process.argv.slice(2);
const selected = path.resolve(__dirname, '../../design/selected');
const source = requestedSource || path.join(selected, JSON.parse(fs.readFileSync(path.join(selected, 'selection.json'), 'utf8')).file);
const svg = fs.readFileSync(source, 'utf8');
if (!svg.includes('<g id="tile">') || !svg.includes('<g id="lunavect-mark"')) {
  throw new Error('Expected the selected Tide artwork with a separate tile and mark');
}
function removeGroup(text, id, includeParent = false) {
  let start = text.indexOf(`<g id="${id}">`);
  if (start < 0) throw new Error('Missing group: ' + id);
  const tags = /<\/?g\b[^>]*>/g;
  if (includeParent) {
    const ancestors = [];
    let tag;
    while ((tag = tags.exec(text)) && tag.index < start) {
      if (tag[0].startsWith('</')) ancestors.pop();
      else ancestors.push(tag.index);
    }
    start = ancestors.at(-1);
    if (start === undefined) throw new Error('Missing object container: ' + id);
  }
  tags.lastIndex = start;
  let depth = 0, match;
  while ((match = tags.exec(text))) {
    depth += match[0].startsWith('</') ? -1 : 1;
    if (depth === 0) return text.slice(0, start) + text.slice(tags.lastIndex);
  }
  throw new Error('Unclosed group: ' + id);
}
function render(name, contents, size) {
  const png = new Resvg(contents, { fitTo: { mode: 'width', value: size } }).render().asPng();
  fs.writeFileSync(path.join(output, name), png);
}
// Tide already includes the 100 px macOS margin. Another inset would shrink it.
render('icon_1024.png', svg, 1024);
const mark = removeGroup(svg, 'tile').replace('viewBox="0 0 1024 1024"', 'viewBox="100 100 824 824"');
render('LunavectMark.png', mark, 512);
// Export actual objects, not vertical halves: Tide's tilted tips cross the centre.
// Include each object's halo and highlight, which are siblings of its shell.
render('LunavectMarkLeft.png', removeGroup(mark, 'right-shell', true), 512);
render('LunavectMarkRight.png', removeGroup(mark, 'left-shell', true), 512);
