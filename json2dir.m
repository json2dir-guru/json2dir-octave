1; % json2dir: create the directory tree a JSON document describes, in the current directory.
% Implements RFC J2D-1 (https://github.com/kitsunoff/awesome-json2dir/blob/main/spec/rfc-json2dir.md).
% Usage: octave-cli json2dir.m < document.json
%
% Uses only Octave built-in functions (it also runs with --no-init-path, where no .m library
% function is available). Octave-only built-ins: argv, lstat, S_ISDIR, symlink, unlink, __mkdir__.
% Execute permission is set through the Java interface (javaObject/javaMethod), which MATLAB
% and Octave both provide, because Octave has no chmod built-in.

function fail(msg)
  error('json2dir:fail', '%s', msg);
end

% Section 3: strict UTF-8 (no overlongs, no surrogates, nothing above U+10FFFF).
% Vectorized: every lead byte must be followed by exactly its number of continuation bytes.
function check_utf8(b)
  b = double(b);
  n = numel(b);
  cont = b >= 128 & b <= 191;
  len = (b >= 194 & b <= 223) + 2 * (b >= 224 & b <= 239) + 3 * (b >= 240 & b <= 244);
  if any(b >= 128 & ~cont & len == 0)
    fail('input is not valid UTF-8');
  end
  covered = false(1, n);
  for d = 1:3
    p = find(len >= d) + d;
    if any(p > n)
      fail('input is not valid UTF-8');
    end
    covered(p) = true;
  end
  % second-byte limits: no overlongs (E0, F0), no surrogates (ED), nothing above U+10FFFF (F4)
  if any(covered ~= cont) || any(b(find(b == 224) + 1) < 160) || any(b(find(b == 237) + 1) > 159) ...
     || any(b(find(b == 240) + 1) < 144) || any(b(find(b == 244) + 1) > 143)
    fail('input is not valid UTF-8');
  end
end

function i = skip_ws(i)
  global B N
  while i <= N && (B(i) == 32 || B(i) == 9 || B(i) == 10 || B(i) == 13)
    i = i + 1;
  end
end

function expect(i, c)
  global B N
  if i > N || B(i) ~= c
    fail(sprintf('input is not valid JSON: expected "%s" at byte %d', char(c), i));
  end
end

function [v, i] = parse_value(i, depth)
  global B N
  if depth > 200
    fail('document is nested too deeply');
  end
  if i > N
    fail('input is not valid JSON: unexpected end of input');
  end
  c = B(i);
  if c == 123  % {
    v = struct('t', 'o');
    v.names = {};
    v.vals = {};
    i = skip_ws(i + 1);
    if i <= N && B(i) == 125
      i = i + 1;
      return;
    end
    while true
      expect(i, 34);
      [name, i] = parse_string(i);
      i = skip_ws(i);
      expect(i, 58);
      [val, i] = parse_value(skip_ws(i + 1), depth + 1);
      m = find(strcmp(v.names, name));  % duplicate names: the last one wins
      if isempty(m)
        v.names{end+1} = name;
        v.vals{end+1} = val;
      else
        v.vals{m} = val;
      end
      i = skip_ws(i);
      if i <= N && B(i) == 44
        i = skip_ws(i + 1);
      else
        expect(i, 125);
        i = i + 1;
        return;
      end
    end
  elseif c == 91  % [
    v = struct('t', 'a');
    v.items = {};
    i = skip_ws(i + 1);
    if i <= N && B(i) == 93
      i = i + 1;
      return;
    end
    while true
      [val, i] = parse_value(i, depth + 1);
      v.items{end+1} = val;
      i = skip_ws(i);
      if i <= N && B(i) == 44
        i = skip_ws(i + 1);
      else
        expect(i, 93);
        i = i + 1;
        return;
      end
    end
  elseif c == 34
    [s, i] = parse_string(i);
    v = struct('t', 's', 's', s);
  else
    i = parse_scalar(i);
    v = struct('t', 'x');
  end
end

% true, false, null and numbers are parsed (to reject bad JSON) but have no meaning here.
function i = parse_scalar(i)
  global B N
  words = {'true', 'false', 'null'};
  for w = 1:3
    word = double(words{w});
    if i + numel(word) - 1 <= N && all(B(i:i+numel(word)-1) == word)
      i = i + numel(word);
      return;
    end
  end
  start = i;
  if i <= N && B(i) == 45, i = i + 1; end
  if i <= N && B(i) == 48
    i = i + 1;
  elseif i <= N && B(i) >= 49 && B(i) <= 57
    i = digits(i);
  else
    fail(sprintf('input is not valid JSON: unexpected byte at %d', start));
  end
  if i <= N && B(i) == 46
    i = need_digits(i + 1);
  end
  if i <= N && (B(i) == 101 || B(i) == 69)
    i = i + 1;
    if i <= N && (B(i) == 43 || B(i) == 45), i = i + 1; end
    i = need_digits(i);
  end
end

function i = digits(i)
  global B N
  while i <= N && B(i) >= 48 && B(i) <= 57
    i = i + 1;
  end
end

function i = need_digits(i)
  j = digits(i);
  if j == i
    fail('input is not valid JSON: bad number');
  end
  i = j;
end

% Returns the string as a char row of its UTF-8 bytes.
function [s, i] = parse_string(i)
  global B N SPEC SK
  i = i + 1;
  out = zeros(1, 16);  % output buffer, doubled when full; n bytes used
  n = 0;
  while true
    while SK <= numel(SPEC) && SPEC(SK) < i
      SK = SK + 1;
    end
    if SK > numel(SPEC)
      fail('input is not valid JSON: unterminated string');
    end
    j = SPEC(SK);
    if n + (j - i) + 4 > numel(out)
      out(2 * (n + (j - i) + 4)) = 0;
    end
    out(n+1:n+j-i) = B(i:j-1);
    n = n + j - i;
    c = B(j);
    if c == 34
      i = j + 1;
      s = char(out(1:n));
      return;
    elseif c < 32
      fail('input is not valid JSON: control character in string');
    end
    if j + 1 > N
      fail('input is not valid JSON: unterminated string');
    end
    e = B(j+1);
    i = j + 2;
    switch e
      case {34, 92, 47}, u = e;
      case 98,  u = 8;
      case 102, u = 12;
      case 110, u = 10;
      case 114, u = 13;
      case 116, u = 9;
      case 117
        cp = hex4(j + 2);
        i = j + 6;
        if cp >= 56320 && cp <= 57343
          fail('string contains an unpaired surrogate');
        elseif cp >= 55296 && cp <= 56319
          if i + 1 > N || B(i) ~= 92 || B(i+1) ~= 117
            fail('string contains an unpaired surrogate');
          end
          lo = hex4(i + 2);
          if lo < 56320 || lo > 57343
            fail('string contains an unpaired surrogate');
          end
          cp = 65536 + (cp - 55296) * 1024 + (lo - 56320);
          i = i + 6;
        end
        u = utf8(cp);
      otherwise
        fail('input is not valid JSON: bad escape');
    end
    out(n+1:n+numel(u)) = u;  % at most 4 bytes, room was reserved above
    n = n + numel(u);
  end
end

function cp = hex4(i)
  global B N
  if i + 3 > N
    fail('input is not valid JSON: bad \u escape');
  end
  cp = 0;
  for k = i:i+3
    c = B(k);
    if c >= 48 && c <= 57, d = c - 48;
    elseif c >= 65 && c <= 70, d = c - 55;
    elseif c >= 97 && c <= 102, d = c - 87;
    else fail('input is not valid JSON: bad \u escape');
    end
    cp = cp * 16 + d;
  end
end

function b = utf8(cp)
  if cp < 128
    b = cp;
  elseif cp < 2048
    b = [192 + floor(cp / 64), 128 + mod(cp, 64)];
  elseif cp < 65536
    b = [224 + floor(cp / 4096), 128 + mod(floor(cp / 64), 64), 128 + mod(cp, 64)];
  else
    b = [240 + floor(cp / 262144), 128 + mod(floor(cp / 4096), 64), ...
         128 + mod(floor(cp / 64), 64), 128 + mod(cp, 64)];
  end
end

% Section 4: validate the whole document before touching the file system.
function validate(v, where)
  switch v.t
    case 's'
    case 'a'
      if numel(v.items) ~= 2 || v.items{1}.t ~= 's' || v.items{2}.t ~= 's'
        fail([where ': an array must be ["link", target] or ["script", content]']);
      end
      kind = v.items{1}.s;
      if ~strcmp(kind, 'link') && ~strcmp(kind, 'script')
        fail([where ': unknown array kind "' kind '"']);
      end
      if strcmp(kind, 'link') && any(v.items{2}.s == 0)
        fail([where ': a link target cannot contain NUL']);
      end
    case 'o'
      for k = 1:numel(v.names)
        name = v.names{k};
        child = [where '/' name];
        if isempty(name) || strcmp(name, '.') || strcmp(name, '..') || any(name == '/') || any(name == 0)
          fail([child ': invalid name']);
        end
        validate(v.vals{k}, child);
      end
    otherwise
      fail([where ': numbers, true, false and null are not allowed']);
  end
end

% A Java string built from UTF-8 bytes (relative paths resolve against the start directory).
function s = jstr(bytes)
  s = javaObject('java.lang.String', typecast(uint8(bytes), 'int8'), 'UTF-8');
end

function write_file(p, content, executable)
  fid = fopen(p, 'w');  % mode 0666 & ~umask; any old entry was removed first
  if fid < 0
    fail([p ': cannot create file']);
  end
  fwrite(fid, uint8(content), 'uint8');
  fclose(fid);
  if executable
    if ~javaMethod('setExecutable', javaObject('java.io.File', jstr(p)), true, false)
      fail([p ': cannot make executable']);
    end
  end
end

function make_link(target, p)
  if ~isempty(target) && target(1) == '~'
    % Octave's symlink() expands a leading "~" in the target, so use Java for these.
    cls = javaMethod('forName', 'java.lang.Class', 'java.nio.file.attribute.FileAttribute');
    none = javaMethod('newInstance', 'java.lang.reflect.Array', cls, 0);
    javaMethod('createSymbolicLink', 'java.nio.file.Files', ...
               javaMethod('toPath', javaObject('java.io.File', jstr(p))), ...
               javaMethod('toPath', javaObject('java.io.File', jstr(target))), none);
  else
    [err, msg] = symlink(target, p);
    if err
      fail([p ': ' msg]);
    end
  end
end

% Paths always start with "./", so no file function ever expands a leading "~".
function apply(dir, v)
  [names, order] = sort(v.names);  % ascending UTF-8 byte order
  for k = 1:numel(names)
    p = [dir '/' names{k}];
    val = v.vals{order(k)};
    [st, err] = lstat(p);
    exists = (err == 0);
    isdir = exists && S_ISDIR(st.mode);
    if strcmp(val.t, 'o')
      if ~isdir
        remove(p, exists);
        [ok, msg] = __mkdir__(p);
        if ~ok
          fail([p ': ' msg]);
        end
      end
      apply(p, val);
    else
      if isdir
        fail([p ': a directory is in the way']);
      end
      remove(p, exists);
      if strcmp(val.t, 's')
        write_file(p, val.s, false);
      elseif strcmp(val.items{1}.s, 'link')
        make_link(val.items{2}.s, p);
      else
        write_file(p, val.items{2}.s, true);
      end
    end
  end
end

% Removes a non-directory entry (a symlink itself, never its target).
function remove(p, exists)
  if exists
    [err, msg] = unlink(p);
    if err
      fail([p ': ' msg]);
    end
  end
end

function status = main(args)
  global B N SPEC SK
  if ~isempty(args)
    fputs(stderr, "usage: json2dir < document.json\n");
    status = 2;
    return;
  end
  try
    b = fread(stdin, Inf, 'uint8=>uint8')';
    check_utf8(b);
    B = double(b);
    if numel(B) >= 3 && all(B(1:3) == [239 187 191])
      B = B(4:end);  % a leading byte order mark is ignored
    end
    N = numel(B);
    SPEC = find(B == 34 | B == 92 | B < 32);
    SK = 1;
    [doc, i] = parse_value(skip_ws(1), 0);
    if skip_ws(i) <= N
      fail('input is not valid JSON: trailing data');
    end
    if ~strcmp(doc.t, 'o')
      fail('the root of the document must be an object');
    end
    validate(doc, '.');
    apply('.', doc);
    status = 0;
  catch e
    fputs(stderr, ['json2dir: ' e.message "\n"]);
    status = 1;
  end
end

exit(main(argv()));
