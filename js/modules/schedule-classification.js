(function initializeScheduleClassification(global) {
  'use strict';

  const KEYWORDS = Object.freeze({
    rest: Object.freeze(['课间操','coffee time','午餐','lunch','午间音乐会','晚餐','dinner','间点','休息','午休','lunch break','大课间','课间','lunchtime']),
    practice: Object.freeze(['练琴','practice session','practice','练习','个人练习']),
    major: Object.freeze([
      '钢琴','piano','钢琴课','钢琴个课','钢琴小课','钢琴大课',
      '小提琴','violin','小提琴课','小提琴个课','小提琴小课','小提琴大课',
      '大提琴','cello','大提琴课','大提琴个课','大提琴小课','大提琴大课',
      '中提琴','viola','低音提琴','double bass','竖琴','harp','吉他','guitar',
      '古筝','二胡','琵琶','古琴','扬琴','中阮','柳琴','三弦',
      '长笛','flute','单簧管','clarinet','双簧管','oboe','大管','巴松','bassoon',
      '萨克斯','saxophone','小号','trumpet','圆号','horn','长号','trombone','大号','tuba',
      '笛子','箫','唢呐','葫芦丝','巴乌',
      '打击乐','percussion','架子鼓','drum','马林巴','marimba','定音鼓','timpani',
      '手风琴','accordion','电子琴','keyboard','管风琴','organ',
      '声乐','vocal','美声','民族声乐','流行声乐','歌唱',
      '作曲','composition','指挥','conducting',
      '专业课程','专业课','主修课','主修','major','1to1 major','1to1'
    ]),
    secondaryMajor: Object.freeze(['二专','二专课','第二专业','第二专业课','secondary major','second major']),
    elective: Object.freeze(['选修','选修课','校本选修','elective','elective course']),
    explicitMajor: Object.freeze(['主修','主修课','专业课','专业课程','专业个课','major','1to1 major','1to1','一对一','个课']),
    assembly: Object.freeze(['校班会','校/班会','班会','school/class assembly','school assembly','class assembly']),
    performance: Object.freeze(['表演课','performance class']),
    musicianship: Object.freeze(['核心音乐素养','core musicianship','音乐素养','musicianship','视唱练耳','solfege','乐理','theory','和声','harmony','复调','counterpoint','曲式','配器']),
    musicStudies: Object.freeze(['音乐历史','音乐史','music history','contextual studies','音乐鉴赏','music appreciation']),
    ensemble: Object.freeze(['合唱','choir','乐团','orchestra','symphony orchestra','管弦乐团','交响乐团','民乐团','室内乐','chamber music','重奏','ensemble']),
    general: Object.freeze(['体育','physical education','pe','美术','art']),
    academic: Object.freeze(['语文','chinese','英语','english','德语','german','数学','math','商务','business','历史','history','地理','geography','科学','science','物理','physics','化学','chemistry','生物','biology','人文','humanities']),
    selfStudy: Object.freeze(['自习','self study'])
  });

  const VISUALS = Object.freeze({
    empty: Object.freeze({label:'空白',fill:'#FFFFFF',text:'#17233D'}),
    course: Object.freeze({label:'其他课程',fill:'#EAF0F8',text:'#344C6A'}),
    academic: Object.freeze({label:'文化课',fill:'#EAF0F8',text:'#344C6A'}),
    general: Object.freeze({label:'体育 / 美术',fill:'#F7ECE3',text:'#7A563C'}),
    practice: Object.freeze({label:'练琴',fill:'#E4F2E8',text:'#276447'}),
    major: Object.freeze({label:'专业课 / 主修课',fill:'#EEE8FA',text:'#563E91'}),
    secondaryMajor: Object.freeze({label:'二专课',fill:'#E1EDFA',text:'#285D8A'}),
    elective: Object.freeze({label:'选修课',fill:'#FFF1D6',text:'#805816'}),
    musicianship: Object.freeze({label:'核心音乐素养',fill:'#DFF1EE',text:'#246761'}),
    musicStudies: Object.freeze({label:'音乐历史 / 鉴赏',fill:'#E4F0F3',text:'#336773'}),
    ensemble: Object.freeze({label:'乐团 / 合唱',fill:'#F5E7EF',text:'#854B67'}),
    performance: Object.freeze({label:'表演课',fill:'#FBE7DC',text:'#8B5136'}),
    assembly: Object.freeze({label:'校班会',fill:'#ECEFF4',text:'#5E6574'}),
    selfStudy: Object.freeze({label:'自习',fill:'#F0EEF6',text:'#625D79'}),
    rest: Object.freeze({label:'休息 / 餐点（无底色）',fill:'#FFFFFF',text:'#667085'})
  });

  const CELL_KINDS = Object.freeze(Object.keys(VISUALS).filter(kind => kind !== 'empty'));
  const CELL_KIND_SET = new Set(CELL_KINDS);
  const LEGEND_KINDS = Object.freeze(['academic','general','practice','major','secondaryMajor','elective','musicianship','musicStudies','ensemble','performance','assembly','selfStudy','rest']);

  function includesKeyword(text, keywords) {
    if (!text) return false;
    const lowerText = String(text).toLowerCase();
    return keywords.some(keyword => {
      const normalizedKeyword = String(keyword).toLowerCase();
      if (!/^[a-z0-9\s]+$/.test(normalizedKeyword)) return lowerText.includes(normalizedKeyword);
      const escapedKeyword = normalizedKeyword.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/\s+/g, '\\s+');
      return new RegExp(`(^|[^a-z0-9])${escapedKeyword}([^a-z0-9]|$)`, 'i').test(lowerText);
    });
  }

  function matchesKind(text, kind) {
    if (kind === 'course' || kind === 'empty') return false;
    return includesKeyword(text, KEYWORDS[kind] || []);
  }

  function classifyCellText(text, forcedKind = 'auto') {
    const normalizedText = String(text || '').trim();
    const requestedKind = CELL_KIND_SET.has(forcedKind) ? forcedKind : 'auto';
    let kind = requestedKind;
    if (requestedKind === 'auto') {
      if (matchesKind(normalizedText, 'rest')) kind = 'rest';
      else if (matchesKind(normalizedText, 'practice')) kind = 'practice';
      else if (matchesKind(normalizedText, 'assembly')) kind = 'assembly';
      else if (matchesKind(normalizedText, 'performance')) kind = 'performance';
      else if (matchesKind(normalizedText, 'secondaryMajor')) kind = 'secondaryMajor';
      else if (matchesKind(normalizedText, 'elective')) kind = 'elective';
      else if (includesKeyword(normalizedText, KEYWORDS.explicitMajor)) kind = 'major';
      else if (matchesKind(normalizedText, 'musicianship')) kind = 'musicianship';
      else if (matchesKind(normalizedText, 'musicStudies')) kind = 'musicStudies';
      else if (matchesKind(normalizedText, 'ensemble')) kind = 'ensemble';
      else if (includesKeyword(normalizedText, KEYWORDS.major)) kind = 'major';
      else if (matchesKind(normalizedText, 'general')) kind = 'general';
      else if (matchesKind(normalizedText, 'academic')) kind = 'academic';
      else if (matchesKind(normalizedText, 'selfStudy')) kind = 'selfStudy';
      else kind = 'course';
    }
    return {
      text: normalizedText,
      kind,
      practice: kind === 'practice',
      rest: kind === 'rest',
      majorCourse: kind === 'major' || kind === 'secondaryMajor'
    };
  }

  function resolvedCellKind(cell) {
    if (!cell) return 'empty';
    if (cell.rest === true) return 'rest';
    if (cell.practice === true) return 'practice';
    if (cell.kind === 'group') {
      const inferredLegacyGroup = classifyCellText(cell.text).kind;
      return inferredLegacyGroup === 'course' ? 'ensemble' : inferredLegacyGroup;
    }
    if (CELL_KIND_SET.has(cell.kind) && cell.kind !== 'course') return cell.kind;
    const inferredKind = classifyCellText(cell.text).kind;
    if (inferredKind !== 'course') return inferredKind;
    return cell.majorCourse === true ? 'major' : 'course';
  }

  function hasCellContent(cell) {
    if (!cell) return false;
    if (String(cell.text || '').trim()) return true;
    if (cell.practice === true || cell.rest === true || cell.majorCourse === true) return true;
    return CELL_KIND_SET.has(cell.kind) && cell.kind !== 'course';
  }

  function normalizeTimeRange(raw) {
    if (!raw) return '';
    const normalized = String(raw).replace(/：/g, ':').trim();
    const pad = value => {
      const [hours, minutes] = value.split(':').map(Number);
      if (!Number.isInteger(hours) || !Number.isInteger(minutes) || hours < 0 || hours > 23 || minutes < 0 || minutes > 59) return '';
      return `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}`;
    };
    const singleTime = normalized.match(/^(\d{1,2}:\d{2})$/);
    if (singleTime) {
      const start = pad(singleTime[1]);
      if (!start) return '';
      const [hours, minutes] = start.split(':').map(Number);
      const endTotal = hours * 60 + minutes + 50;
      if (endTotal > 24 * 60 - 1) return '';
      const end = `${String(Math.floor(endTotal / 60)).padStart(2, '0')}:${String(endTotal % 60).padStart(2, '0')}`;
      return `${start}-${end}`;
    }
    const match = normalized.match(/(\d{1,2}:\d{2})\s*[-—－–]\s*(\d{1,2}:\d{2})/);
    if (!match) return '';
    const start = pad(match[1]);
    const end = pad(match[2]);
    return start && end ? `${start}-${end}` : '';
  }

  function timeRangeBounds(raw) {
    const normalized = normalizeTimeRange(raw);
    if (!normalized) return null;
    const [start, end] = normalized.split('-').map(value => {
      const [hours, minutes] = value.split(':').map(Number);
      return hours * 60 + minutes;
    });
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) return null;
    return {start, end};
  }

  function mergeScheduleCells(current, next) {
    if (!current) return {...next};
    if (!current.text && next.text) return {...next};
    if (current.text && next.text && current.text !== next.text && !current.text.includes(next.text)) {
      current.text += `\n${next.text}`;
    }
    current.practice = current.practice === true || next.practice === true;
    current.rest = current.rest === true || next.rest === true;
    current.majorCourse = current.majorCourse === true || next.majorCourse === true;
    return current;
  }

  function buildScheduleDisplayLayout(cells, options = {}) {
    const normalSlots = Array.isArray(options.normalSlots) ? options.normalSlots.map(normalizeTimeRange).filter(Boolean) : [];
    const fallbackSlots = Array.isArray(options.fallbackSlots)
      ? options.fallbackSlots.map(normalizeTimeRange).filter(Boolean)
      : normalSlots;
    const dayCount = Number.isInteger(options.dayCount) && options.dayCount > 0 ? options.dayCount : 7;
    const entriesByTime = new Map();
    Object.entries(cells || {}).forEach(([key, cell]) => {
      const match = key.match(/^(\d+)_(\d+)$/);
      if (!match) return;
      const slotIndex = Number(match[1]);
      const day = Number(match[2]);
      if (!Number.isInteger(day) || day < 0 || day >= dayCount) return;
      const time = normalizeTimeRange(cell?.time) || fallbackSlots[slotIndex] || normalSlots[slotIndex] || '';
      if (!time || !timeRangeBounds(time)) return;
      let entry = entriesByTime.get(time);
      if (!entry) {
        entry = {time, cells: new Map()};
        entriesByTime.set(time, entry);
      }
      const next = {...(cell || {}), time, day, text: String(cell?.text || '')};
      entry.cells.set(day, mergeScheduleCells(entry.cells.get(day), next));
    });

    const entries = [...entriesByTime.values()].sort((left, right) => {
      const leftBounds = timeRangeBounds(left.time);
      const rightBounds = timeRangeBounds(right.time);
      return leftBounds.start - rightBounds.start || leftBounds.end - rightBounds.end;
    });
    const groups = [];
    entries.forEach(entry => {
      const bounds = timeRangeBounds(entry.time);
      const previous = groups[groups.length - 1];
      if (previous && bounds.start < previous.end) {
        previous.entries.push(entry);
        previous.end = Math.max(previous.end, bounds.end);
      } else {
        groups.push({entries: [entry], end: bounds.end});
      }
    });

    const axis = [];
    const displayCells = {};
    groups.forEach(group => {
      const rankedEntries = group.entries.map((entry, index) => ({
        entry,
        index,
        score: [...entry.cells.values()].reduce((sum, cell) => sum + (String(cell.text || '').trim() ? 2 : 0) + (hasCellContent(cell) ? 1 : 0), 0)
      })).sort((left, right) => right.score - left.score || left.index - right.index);
      const displayTime = rankedEntries[0].entry.time;
      axis.push(displayTime);
      const mergedByDay = new Map();
      group.entries.forEach(entry => entry.cells.forEach((sourceCell, day) => {
        const merged = mergeScheduleCells(mergedByDay.get(day), {...sourceCell, time: displayTime, day});
        mergedByDay.set(day, merged);
      }));
      mergedByDay.forEach((cell, day) => { displayCells[`${displayTime}|${day}`] = cell; });
    });
    return {axis: [...new Set(axis)], cells: displayCells};
  }

  function visualForCell(cell) {
    const kind = hasCellContent(cell) ? resolvedCellKind(cell) : 'empty';
    return Object.freeze({kind, ...VISUALS[kind]});
  }

  global.ScheduleClassification = Object.freeze({
    KEYWORDS,
    VISUALS,
    CELL_KINDS,
    LEGEND_KINDS,
    includesKeyword,
    matchesKind,
    classifyCellText,
    resolvedCellKind,
    hasCellContent,
    normalizeTimeRange,
    timeRangeBounds,
    buildScheduleDisplayLayout,
    visualForCell
  });
})(window);
