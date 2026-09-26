

import sys, os
# Ensure backend package folder is on path so imports work when executed from different cwd
ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__)))
if ROOT_DIR not in sys.path:
    sys.path.insert(0, ROOT_DIR)
try:
    from backend.dsl_functions import DSL_FUNCTIONS, _set_current_instrumentid, _set_current_postingdate, _set_current_subinstrumentid, _clear_transaction_results, _get_transaction_results, _set_dsl_print
except Exception:
    from dsl_functions import DSL_FUNCTIONS, _set_current_instrumentid, _set_current_postingdate, _set_current_subinstrumentid, _clear_transaction_results, _get_transaction_results, _set_dsl_print
from datetime import datetime
import json

# Preserve Python built-ins before updating with DSL functions
_builtin_min = min
_builtin_max = max
_builtin_sum = sum
_builtin_len = len
_builtin_range = range
_builtin_print = print

# Make all DSL functions available globally
globals().update(DSL_FUNCTIONS)

# Expose safe aliases for DSL functions whose names are Python keywords
and_op = DSL_FUNCTIONS.get('and', lambda a, b: a and b)
or_op = DSL_FUNCTIONS.get('or', lambda a, b: a or b)
not_op = DSL_FUNCTIONS.get('not', lambda a: not a)

# Restore Python built-ins (needed for native Python syntax)
min = _builtin_min
max = _builtin_max
sum = _builtin_sum
len = _builtin_len
# Smart range: DSL range(list)->max-min; Python range(int,...) for iterations
_dsl_range_val = DSL_FUNCTIONS.get('range', lambda col: (_builtin_max(col) - _builtin_min(col)) if col else 0)
def range(*args):
    if len(args) == 1 and isinstance(args[0], list):
        return _dsl_range_val(args[0])
    return _builtin_range(*args)

# Global list to capture print outputs
_print_outputs = []

def dsl_print(*args, **kwargs):
    """Custom print function that captures output for display in console"""
    try:
        # If a single argument looks like schedule(s), delegate to print_all_schedules
        if len(args) == 1:
            obj = args[0]
            if isinstance(obj, list) and obj:
                first = obj[0]
                if isinstance(first, dict) and 'schedule' in first:
                    try:
                        print_all_schedules(obj)
                        return
                    except Exception:
                        pass
                if isinstance(first, list):
                    inner_first = first[0] if first else None
                    if isinstance(inner_first, dict) and ('period_date' in inner_first or 'period_revenue' in inner_first or 'period_amount' in inner_first):
                        try:
                            print_all_schedules(obj)
                            return
                        except Exception:
                            pass
                    try:
                        print_all_schedules(obj)
                        return
                    except Exception:
                        pass
                if isinstance(first, dict) and ('period_date' in first or 'period_revenue' in first or 'period_amount' in first):
                    try:
                        # treat as array of rows (single schedule)
                        print_all_schedules([{"schedule": obj}])
                        return
                    except Exception:
                        pass
            if isinstance(obj, dict) and 'schedule' in obj:
                try:
                    print_all_schedules([obj])
                    return
                except Exception:
                    pass

        output_parts = []
        for arg in args:
            if isinstance(arg, (list, dict)):
                # Pretty print complex objects
                try:
                    output_parts.append(json.dumps(arg, indent=2, default=str))
                except Exception:
                    output_parts.append(str(arg))
            else:
                output_parts.append(str(arg))

        sep = kwargs.get('sep', ' ')
        output = sep.join(output_parts)
        _print_outputs.append(output)
    except Exception:
        try:
            _builtin_print(' '.join(map(str, args)))
        except Exception:
            pass

# Override print with our custom version
print = dsl_print

# Set the DSL print function for use by dsl_functions module (e.g., print_schedule)
_set_dsl_print(dsl_print)

def get_field_case_insensitive(row, field_name, default=''):
    """Get field value with case-insensitive key matching"""
    if field_name in row:
        return row[field_name]
    field_lower = field_name.lower()
    for key in row:
        if key.lower() == field_lower:
            return row[key]
    return default

def get_print_outputs():
    """Return all captured print outputs"""
    return _print_outputs

def clear_print_outputs():
    """Clear captured print outputs"""
    global _print_outputs
    _print_outputs = []

# Global reference to all event data for collect() function
_all_event_data = []
_raw_event_data = {}  # Raw data by event name: {'ECF': [...], 'PMT': [...]}
_current_context = {}

def set_all_event_data(data):
    """Set the global event data reference"""
    global _all_event_data
    _all_event_data = data

def set_raw_event_data(data):
    """Set the raw event data (unmerged) for collect() functions"""
    global _raw_event_data
    if not isinstance(data, dict):
        # Refuse to corrupt global state — something upstream passed the wrong type.
        # Reset to empty so collect_*() functions return [] instead of crashing later
        # with the cryptic ``'str' object has no attribute 'items'``.
        try:
            _builtin_print(
                f"[dsl-template warning] set_raw_event_data got {type(data).__name__}; expected dict. Resetting to empty."
            )
        except Exception:
            pass
        _raw_event_data = {}
        return
    _raw_event_data = data

def set_current_context(instrumentid, postingdate, effectivedate, subinstrumentid='1'):
    """Set the current row context for filtering collect_by_* functions"""
    global _current_context
    _current_context = {
        'instrumentid': instrumentid,
        'subinstrumentid': subinstrumentid or '1',
        'postingdate': postingdate,
        'effectivedate': effectivedate
    }

# Fields that are IDENTIFIERS, not measures. Coercing these to float turned
# subinstrumentid '1' into 1.0, so a natural join like
#   lookup(amounts, sub_ids, subinstrumentid)
# silently returned None -- the row built-in `subinstrumentid` is the STRING
# '1'. Everything else on the platform (row built-ins, TransactionOutput,
# merged event data) keeps these as strings, so collect_*() does too.
_IDENTIFIER_FIELDS = ('instrumentid', 'subinstrumentid')


def _is_identifier_field(actual_field, field_name):
    """True when the collected field is an id rather than a measure."""
    for candidate in (actual_field, field_name):
        if isinstance(candidate, str) and candidate.lower() in _IDENTIFIER_FIELDS:
            return True
    return False


def _row_has_field(row, name):
    """True when `row` carries `name` (case-insensitive)."""
    if not isinstance(row, dict) or not isinstance(name, str):
        return False
    if name in row:
        return True
    lowered = name.lower()
    for key in row:
        if str(key).lower() == lowered:
            return True
    return False


def _no_such_collect_field(fn_name, field_name, actual_field):
    """
    Message for a collect_*() whose field exists in no loaded event.

    This used to return one blank per scanned row -- an array of '' sized to
    the ACTIVITY row count, which looks like real data and quietly zeroed
    every downstream total. It happens when a reference event is named only
    inside a quoted collector argument: nothing detects the reference, so
    the event is never loaded for the run.
    """
    loaded = sorted(_raw_event_data.keys())
    known = []
    for evt in loaded:
        rows = _raw_event_data.get(evt) or []
        if rows and isinstance(rows[0], dict):
            known.append(evt + '(' + ', '.join(sorted(rows[0].keys())) + ')')
        else:
            known.append(evt + '(no rows)')
    return (
        fn_name + '(' + repr(field_name) + '): no loaded event supplies a '
        'field named ' + repr(actual_field) + '. Loaded events: '
        + ('; '.join(known) if known else '(none)') + '. '
        'If the event name is part of that string, reference it in DOTTED '
        'form instead -- ' + fn_name + '(EVENTNAME.fieldname) -- so the run '
        'actually loads the event. A quoted name is invisible to the '
        'event loader.')


def _split_event_field(field_name):
    """
    Split a flattened 'EVENTNAME_fieldname' reference into (event, field).

    An event name may itself contain underscores (SO_EVENT, line_items,
    sales_order). A naive field_name.split('_', 1) then picks the WRONG
    boundary -- 'SO_EVENT_line_amount' parsed as event 'SO' + field
    'EVENT_line_amount' -- which matches no event, so every collect_*()
    call silently returned []. Resolve against the event names we actually
    hold, longest first, so 'SO_EVENT' wins over a hypothetical 'SO'.

    Returns (None, field_name) when no known event prefixes the name: that
    means 'a bare field, look in every event', which is what a caller who
    passed an unprefixed name intends.
    """
    if not isinstance(field_name, str):
        return None, field_name
    lowered = field_name.lower()
    for evt in sorted(_raw_event_data.keys(), key=len, reverse=True):
        prefix = str(evt).lower() + '_'
        if lowered.startswith(prefix) and len(field_name) > len(prefix):
            return evt, field_name[len(prefix):]
    return None, field_name


def collect_by_instrument(field_name):
    """
    Collect all values of a field for the current instrumentid only (ignores dates).
    Useful for time-series data across multiple periods for same instrument.
    Returns numeric values as floats, non-numeric (dates, strings) as strings.

    Results are sorted by subinstrumentid (numeric-aware) so arrays produced
    by separate collect_by_instrument() calls in the same rule line up index
    for index across instruments. Without this sort, collect_by_instrument(REV.x)
    and collect_by_instrument(REV.y) could end up in different orders for
    different instruments and break index-based joins.
    """
    pairs = []
    found_field = False
    current_instrument = _current_context.get('instrumentid', '')

    # Parse field_name (event names may contain underscores)
    event_name, actual_field = _split_event_field(field_name)

    for evt_name, rows in _raw_event_data.items():
        if event_name and evt_name.upper() != event_name.upper():
            continue

        for row in rows:
            row_instrument = get_field_case_insensitive(row, 'instrumentid', '')

            if row_instrument == current_instrument:
                if _row_has_field(row, actual_field) or _row_has_field(row, field_name):
                    found_field = True
                val = get_field_case_insensitive(row, actual_field, None)
                if val is None:
                    val = get_field_case_insensitive(row, field_name, None)
                # Always emit a row per subinstrument so parallel arrays stay
                # index-aligned. Type-aware placeholder is decided after the
                # scan so dates/strings don't get coerced to 0.
                sub = get_field_case_insensitive(row, 'subinstrumentid', '') or ''
                pairs.append((str(sub), val))

    # Scanned rows but the field was on none of them -> the caller named a
    # field (or an event) this run never loaded. Say so instead of handing
    # back a plausible-looking array of blanks.
    if pairs and not found_field:
        raise ValueError(_no_such_collect_field(
            'collect_by_instrument', field_name, actual_field))

    # Decide whether this is a numeric field. If every non-null value parses
    # as a number, missing entries become 0; otherwise they become ''. This
    # preserves subinstrument alignment without polluting date/string arrays
    # with a meaningless 0.
    all_numeric = True
    has_value = False
    for _s, v in pairs:
        if v is None or v == '':
            continue
        has_value = True
        try:
            float(v)
        except (ValueError, TypeError):
            all_numeric = False
            break
    # Identifier arrays stay textual end-to-end, so a missing id must be an
    # empty string too - never an int 0 sitting among string ids.
    _keep_as_text = _is_identifier_field(actual_field, field_name)
    null_placeholder = 0 if (has_value and all_numeric and not _keep_as_text) else ''

    converted = []
    for s, v in pairs:
        if v is None or v == '':
            converted.append((s, null_placeholder))
        elif _keep_as_text:
            converted.append((s, str(v)))
        else:
            try:
                converted.append((s, float(v)))
            except (ValueError, TypeError):
                converted.append((s, str(v)))
    pairs = converted

    def _sort_key(p):
        s = p[0]
        try:
            return (0, float(s))
        except (ValueError, TypeError):
            return (1, s)

    pairs.sort(key=_sort_key)
    sub_ids = [s for s, _v in pairs]
    values = [v for _s, v in pairs]
    try:
        from dsl_functions import _ScheduleValueList
        return _ScheduleValueList(values, subinstrument_ids=sub_ids)
    except Exception:
        return values

def collect_all(field_name):
    """
    Collect ALL values of a field across all data rows (no filtering).
    Returns numeric values as floats, non-numeric (dates, strings) as strings.

    Results are sorted by subinstrumentid (numeric-aware) where present so
    parallel collect_all() arrays stay aligned by index. Reference tables
    without subinstrumentid keep their natural row order.
    """
    pairs = []
    found_field = False

    # Parse field_name (event names may contain underscores)
    event_name, actual_field = _split_event_field(field_name)

    for evt_name, rows in _raw_event_data.items():
        if event_name and evt_name.upper() != event_name.upper():
            continue

        for idx, row in enumerate(rows):
            if _row_has_field(row, actual_field) or _row_has_field(row, field_name):
                found_field = True
            val = get_field_case_insensitive(row, actual_field, None)
            if val is None:
                val = get_field_case_insensitive(row, field_name, None)
            # Always emit a row so parallel collect_all() arrays stay
            # index-aligned. Type-aware placeholder is decided after scan.
            sub = get_field_case_insensitive(row, 'subinstrumentid', '') or ''
            pairs.append((str(sub), idx, val))

    if pairs and not found_field:
        raise ValueError(_no_such_collect_field(
            'collect_all', field_name, actual_field))

    all_numeric = True
    has_value = False
    for _s, _i, v in pairs:
        if v is None or v == '':
            continue
        has_value = True
        try:
            float(v)
        except (ValueError, TypeError):
            all_numeric = False
            break
    # Identifier arrays stay textual end-to-end, so a missing id must be an
    # empty string too - never an int 0 sitting among string ids.
    _keep_as_text = _is_identifier_field(actual_field, field_name)
    null_placeholder = 0 if (has_value and all_numeric and not _keep_as_text) else ''

    converted = []
    for s, i, v in pairs:
        if v is None or v == '':
            converted.append((s, i, null_placeholder))
        elif _keep_as_text:
            converted.append((s, i, str(v)))
        else:
            try:
                converted.append((s, i, float(v)))
            except (ValueError, TypeError):
                converted.append((s, i, str(v)))
    pairs = converted

    def _sort_key(p):
        s = p[0]
        if s == '':
            # Reference/no-sub rows keep insertion order via the idx tiebreaker.
            return (2, p[1])
        try:
            return (0, float(s), p[1])
        except (ValueError, TypeError):
            return (1, s, p[1])

    pairs.sort(key=_sort_key)
    return [v for _s, _i, v in pairs]

def collect_by_subinstrument(field_name):
    """
    Collect all values of a field for the current instrumentid AND subinstrumentid.
    Useful when you need to filter by both parent and child entity.
    
    Hierarchy: postingDate → instrumentId → subInstrumentId → effectiveDates
    """
    values = []
    found_field = False
    scanned = False
    current_instrument = _current_context.get('instrumentid', '')
    current_subinstrument = _current_context.get('subinstrumentid', '1')
    
    # Parse field_name (event names may contain underscores)
    event_name, actual_field = _split_event_field(field_name)
    
    for evt_name, rows in _raw_event_data.items():
        if event_name and evt_name.upper() != event_name.upper():
            continue
            
        for row in rows:
            row_instrument = get_field_case_insensitive(row, 'instrumentid', '')
            row_subinstrument = get_field_case_insensitive(row, 'subinstrumentid', '1') or '1'
            
            if row_instrument == current_instrument and row_subinstrument == current_subinstrument:
                scanned = True
                if _row_has_field(row, actual_field) or _row_has_field(row, field_name):
                    found_field = True
                val = get_field_case_insensitive(row, actual_field, None)
                if val is None:
                    val = get_field_case_insensitive(row, field_name, None)
                if val is not None and val != '':
                    if _is_identifier_field(actual_field, field_name):
                        values.append(str(val))
                    else:
                        try:
                            values.append(float(val))
                        except (ValueError, TypeError):
                            # For non-numeric values, store as string
                            values.append(val)
    if scanned and not found_field:
        raise ValueError(_no_such_collect_field(
            'collect_by_subinstrument', field_name, actual_field))
    return values

def collect_effectivedates_for_subinstrument(subinstrument_id=None):
    """
    Collect all unique effectiveDates for a specific subInstrumentId within current instrumentId.
    If subinstrument_id is None, uses current context's subinstrumentid.
    """
    current_instrument = _current_context.get('instrumentid', '')
    target_subinstrument = subinstrument_id or _current_context.get('subinstrumentid', '1')
    effective_dates = set()
    
    for evt_name, rows in _raw_event_data.items():
        for row in rows:
            row_instrument = get_field_case_insensitive(row, 'instrumentid', '')
            row_subinstrument = get_field_case_insensitive(row, 'subinstrumentid', '1') or '1'
            
            if row_instrument == current_instrument and row_subinstrument == target_subinstrument:
                edate = get_field_case_insensitive(row, 'effectivedate', '')
                if edate:
                    effective_dates.add(edate)
    
    return sorted(list(effective_dates))

def process_event_data(event_data, raw_event_data=None, override_postingdate=None, override_effectivedate=None):
    # Clear any previous transaction results
    _clear_transaction_results()
    
    _override_postingdate = override_postingdate
    _override_effectivedate = override_effectivedate
    
    # If raw event data provided by the caller, set it for collect() functions
    if raw_event_data is not None:
        set_raw_event_data(raw_event_data)

    # Set global event data for collect() function
    set_all_event_data(event_data)

    # Activity-data ordering guarantee: enforce
    #   instrumentid ASC, postingdate ASC, effectivedate ASC, subinstrumentid ASC
    # so every step inside this rule (Schedule, Condition, Iteration,
    # Calculation, Custom Code, Create Transaction) sees rows in the same
    # canonical order. event_data here is the merged ACTIVITY dataset only;
    # reference/custom rows live in raw_event_data and are not touched.
    try:
        if isinstance(event_data, list) and len(event_data) > 1:
            event_data.sort(key=lambda _r: (
                str(get_field_case_insensitive(_r, 'instrumentid', '') or ''),
                str(get_field_case_insensitive(_r, 'postingdate', '') or ''),
                str(get_field_case_insensitive(_r, 'effectivedate', '') or ''),
                str(get_field_case_insensitive(_r, 'subinstrumentid', '1') or '1'),
            ))
    except Exception:
        pass
    
    for row in event_data:
        # Extract standard fields (case-insensitive)
        postingdate = get_field_case_insensitive(row, 'postingdate', '')
        effectivedate = get_field_case_insensitive(row, 'effectivedate', '') or postingdate
        instrumentid = get_field_case_insensitive(row, 'instrumentid', '')
        subinstrumentid = get_field_case_insensitive(row, 'subinstrumentid', '1') or '1'
        # Expose underscore aliases so schedule column formulas can reference them
        posting_date = postingdate
        effective_date = effectivedate
        
        # Set current instrumentid for createTransaction()
        _set_current_instrumentid(instrumentid)
        # Set current sub-instrument so schedule() can bind the
        # `subinstrument_id` column built-in to this row.
        _set_current_subinstrumentid(subinstrumentid)
        # Set current postingdate so print_schedule() can tag emitted rows
        # with (_instrumentid, _postingdate) for the Business Preview filter.
        _set_current_postingdate(postingdate)
        
        # Set current context for collect() filtering
        set_current_context(instrumentid, postingdate, effectivedate, subinstrumentid)
        
        # Extract fields from all events with proper datatype conversion
        # Fields from BILLING_SCHEDULE (activity)
        BILLING_SCHEDULE_postingdate = str(get_field_case_insensitive(row, 'BILLING_SCHEDULE_postingdate', ''))
        BILLING_SCHEDULE_effectivedate = str(get_field_case_insensitive(row, 'BILLING_SCHEDULE_effectivedate', ''))
        BILLING_SCHEDULE_subinstrumentid = str(get_field_case_insensitive(row, 'BILLING_SCHEDULE_subinstrumentid', '1'))
        _fv = get_field_case_insensitive(row, 'BILLING_SCHEDULE_product_code', '')
        if isinstance(_fv, (int, float)):
            BILLING_SCHEDULE_product_code = _fv
        else:
            _s = str(_fv if _fv is not None else '')
            try: BILLING_SCHEDULE_product_code = float(_s) if _s.strip() else _s
            except (ValueError, TypeError): BILLING_SCHEDULE_product_code = _s
        BILLING_SCHEDULE_billing_amount = float(get_field_case_insensitive(row, 'BILLING_SCHEDULE_billing_amount', 0) or 0)
        _fv = get_field_case_insensitive(row, 'BILLING_SCHEDULE_invoice_number', '')
        if isinstance(_fv, (int, float)):
            BILLING_SCHEDULE_invoice_number = _fv
        else:
            _s = str(_fv if _fv is not None else '')
            try: BILLING_SCHEDULE_invoice_number = float(_s) if _s.strip() else _s
            except (ValueError, TypeError): BILLING_SCHEDULE_invoice_number = _s
        _fv = get_field_case_insensitive(row, 'BILLING_SCHEDULE_reference_invoice_number', '')
        if isinstance(_fv, (int, float)):
            BILLING_SCHEDULE_reference_invoice_number = _fv
        else:
            _s = str(_fv if _fv is not None else '')
            try: BILLING_SCHEDULE_reference_invoice_number = float(_s) if _s.strip() else _s
            except (ValueError, TypeError): BILLING_SCHEDULE_reference_invoice_number = _s
        # Fields from SALE_ORDER_DETAILS (activity)
        SALE_ORDER_DETAILS_postingdate = str(get_field_case_insensitive(row, 'SALE_ORDER_DETAILS_postingdate', ''))
        SALE_ORDER_DETAILS_effectivedate = str(get_field_case_insensitive(row, 'SALE_ORDER_DETAILS_effectivedate', ''))
        SALE_ORDER_DETAILS_subinstrumentid = str(get_field_case_insensitive(row, 'SALE_ORDER_DETAILS_subinstrumentid', '1'))
        SALE_ORDER_DETAILS_ATTRIBUTE_BOOKINGS_AMOUNT_CURRENT = float(get_field_case_insensitive(row, 'SALE_ORDER_DETAILS_ATTRIBUTE_BOOKINGS_AMOUNT_CURRENT', 0) or 0)
        _fv = get_field_case_insensitive(row, 'SALE_ORDER_DETAILS_ATTRIBUTE_CURRENCY_CURRENT', '')
        if isinstance(_fv, (int, float)):
            SALE_ORDER_DETAILS_ATTRIBUTE_CURRENCY_CURRENT = _fv
        else:
            _s = str(_fv if _fv is not None else '')
            try: SALE_ORDER_DETAILS_ATTRIBUTE_CURRENCY_CURRENT = float(_s) if _s.strip() else _s
            except (ValueError, TypeError): SALE_ORDER_DETAILS_ATTRIBUTE_CURRENCY_CURRENT = _s
        _fv = get_field_case_insensitive(row, 'SALE_ORDER_DETAILS_ATTRIBUTE_DURATION_CURRENT', '')
        if isinstance(_fv, (int, float)):
            SALE_ORDER_DETAILS_ATTRIBUTE_DURATION_CURRENT = _fv
        else:
            _s = str(_fv if _fv is not None else '')
            try: SALE_ORDER_DETAILS_ATTRIBUTE_DURATION_CURRENT = float(_s) if _s.strip() else _s
            except (ValueError, TypeError): SALE_ORDER_DETAILS_ATTRIBUTE_DURATION_CURRENT = _s
        _fv = get_field_case_insensitive(row, 'SALE_ORDER_DETAILS_ATTRIBUTE_INVOICE_NUMBER_CURRENT', '')
        if isinstance(_fv, (int, float)):
            SALE_ORDER_DETAILS_ATTRIBUTE_INVOICE_NUMBER_CURRENT = _fv
        else:
            _s = str(_fv if _fv is not None else '')
            try: SALE_ORDER_DETAILS_ATTRIBUTE_INVOICE_NUMBER_CURRENT = float(_s) if _s.strip() else _s
            except (ValueError, TypeError): SALE_ORDER_DETAILS_ATTRIBUTE_INVOICE_NUMBER_CURRENT = _s
        _fv = get_field_case_insensitive(row, 'SALE_ORDER_DETAILS_ATTRIBUTE_MRR_CURRENT', '')
        if isinstance(_fv, (int, float)):
            SALE_ORDER_DETAILS_ATTRIBUTE_MRR_CURRENT = _fv
        else:
            _s = str(_fv if _fv is not None else '')
            try: SALE_ORDER_DETAILS_ATTRIBUTE_MRR_CURRENT = float(_s) if _s.strip() else _s
            except (ValueError, TypeError): SALE_ORDER_DETAILS_ATTRIBUTE_MRR_CURRENT = _s
        _fv = get_field_case_insensitive(row, 'SALE_ORDER_DETAILS_ATTRIBUTE_PRODUCT_ID_CURRENT', '')
        if isinstance(_fv, (int, float)):
            SALE_ORDER_DETAILS_ATTRIBUTE_PRODUCT_ID_CURRENT = _fv
        else:
            _s = str(_fv if _fv is not None else '')
            try: SALE_ORDER_DETAILS_ATTRIBUTE_PRODUCT_ID_CURRENT = float(_s) if _s.strip() else _s
            except (ValueError, TypeError): SALE_ORDER_DETAILS_ATTRIBUTE_PRODUCT_ID_CURRENT = _s
        SALE_ORDER_DETAILS_ATTRIBUTE_QUANTITY_CURRENT = float(get_field_case_insensitive(row, 'SALE_ORDER_DETAILS_ATTRIBUTE_QUANTITY_CURRENT', 0) or 0)
        _fv = get_field_case_insensitive(row, 'SALE_ORDER_DETAILS_ATTRIBUTE_REFERENCE_INVOICE_NUMBER_CURRENT', '')
        if isinstance(_fv, (int, float)):
            SALE_ORDER_DETAILS_ATTRIBUTE_REFERENCE_INVOICE_NUMBER_CURRENT = _fv
        else:
            _s = str(_fv if _fv is not None else '')
            try: SALE_ORDER_DETAILS_ATTRIBUTE_REFERENCE_INVOICE_NUMBER_CURRENT = float(_s) if _s.strip() else _s
            except (ValueError, TypeError): SALE_ORDER_DETAILS_ATTRIBUTE_REFERENCE_INVOICE_NUMBER_CURRENT = _s
        SALE_ORDER_DETAILS_ATTRIBUTE_SALE_PRICE_CURRENT = float(get_field_case_insensitive(row, 'SALE_ORDER_DETAILS_ATTRIBUTE_SALE_PRICE_CURRENT', 0) or 0)
        SALE_ORDER_DETAILS_ATTRIBUTE_SERVICE_END_DATE_CURRENT = str(get_field_case_insensitive(row, 'SALE_ORDER_DETAILS_ATTRIBUTE_SERVICE_END_DATE_CURRENT', ''))
        SALE_ORDER_DETAILS_ATTRIBUTE_SERVICE_START_DATE_CURRENT = str(get_field_case_insensitive(row, 'SALE_ORDER_DETAILS_ATTRIBUTE_SERVICE_START_DATE_CURRENT', ''))
        _fv = get_field_case_insensitive(row, 'SALE_ORDER_DETAILS_ATTRIBUTE_SUBSCRIPTION_ID_CURRENT', '')
        if isinstance(_fv, (int, float)):
            SALE_ORDER_DETAILS_ATTRIBUTE_SUBSCRIPTION_ID_CURRENT = _fv
        else:
            _s = str(_fv if _fv is not None else '')
            try: SALE_ORDER_DETAILS_ATTRIBUTE_SUBSCRIPTION_ID_CURRENT = float(_s) if _s.strip() else _s
            except (ValueError, TypeError): SALE_ORDER_DETAILS_ATTRIBUTE_SUBSCRIPTION_ID_CURRENT = _s
        SALE_ORDER_DETAILS_ATTRIBUTE_TRANSACTIONDATE_CURRENT = str(get_field_case_insensitive(row, 'SALE_ORDER_DETAILS_ATTRIBUTE_TRANSACTIONDATE_CURRENT', ''))
        # Fields from REVENUE_BALANCE (activity)
        REVENUE_BALANCE_postingdate = str(get_field_case_insensitive(row, 'REVENUE_BALANCE_postingdate', ''))
        REVENUE_BALANCE_effectivedate = str(get_field_case_insensitive(row, 'REVENUE_BALANCE_effectivedate', ''))
        REVENUE_BALANCE_subinstrumentid = str(get_field_case_insensitive(row, 'REVENUE_BALANCE_subinstrumentid', '1'))
        REVENUE_BALANCE_BALANCES_BEGINNINGBALANCE_TOTAL_REVENUE = float(get_field_case_insensitive(row, 'REVENUE_BALANCE_BALANCES_BEGINNINGBALANCE_TOTAL_REVENUE', 0) or 0)
        REVENUE_BALANCE_BALANCES_ENDINGBALANCE_TOTAL_REVENUE = float(get_field_case_insensitive(row, 'REVENUE_BALANCE_BALANCES_ENDINGBALANCE_TOTAL_REVENUE', 0) or 0)
        REVENUE_BALANCE_BALANCES_ACTIVITY_TOTAL_REVENUE = float(get_field_case_insensitive(row, 'REVENUE_BALANCE_BALANCES_ACTIVITY_TOTAL_REVENUE', 0) or 0)
        # Fields from PROF_SERVICE_DELIVERY (activity)
        PROF_SERVICE_DELIVERY_postingdate = str(get_field_case_insensitive(row, 'PROF_SERVICE_DELIVERY_postingdate', ''))
        PROF_SERVICE_DELIVERY_effectivedate = str(get_field_case_insensitive(row, 'PROF_SERVICE_DELIVERY_effectivedate', ''))
        PROF_SERVICE_DELIVERY_subinstrumentid = str(get_field_case_insensitive(row, 'PROF_SERVICE_DELIVERY_subinstrumentid', '1'))
        _fv = get_field_case_insensitive(row, 'PROF_SERVICE_DELIVERY_product_code', '')
        if isinstance(_fv, (int, float)):
            PROF_SERVICE_DELIVERY_product_code = _fv
        else:
            _s = str(_fv if _fv is not None else '')
            try: PROF_SERVICE_DELIVERY_product_code = float(_s) if _s.strip() else _s
            except (ValueError, TypeError): PROF_SERVICE_DELIVERY_product_code = _s
        _fv = get_field_case_insensitive(row, 'PROF_SERVICE_DELIVERY_service_delivery_id', '')
        if isinstance(_fv, (int, float)):
            PROF_SERVICE_DELIVERY_service_delivery_id = _fv
        else:
            _s = str(_fv if _fv is not None else '')
            try: PROF_SERVICE_DELIVERY_service_delivery_id = float(_s) if _s.strip() else _s
            except (ValueError, TypeError): PROF_SERVICE_DELIVERY_service_delivery_id = _s
        PROF_SERVICE_DELIVERY_units_delivered = float(get_field_case_insensitive(row, 'PROF_SERVICE_DELIVERY_units_delivered', 0) or 0)
        # Fields from SSP_RULE (reference)
        _fv = get_field_case_insensitive(row, 'SSP_RULE_product_code', '')
        if isinstance(_fv, (int, float)):
            SSP_RULE_product_code = _fv
        else:
            _s = str(_fv if _fv is not None else '')
            try: SSP_RULE_product_code = float(_s) if _s.strip() else _s
            except (ValueError, TypeError): SSP_RULE_product_code = _s
        _fv = get_field_case_insensitive(row, 'SSP_RULE_recognition_method', '')
        if isinstance(_fv, (int, float)):
            SSP_RULE_recognition_method = _fv
        else:
            _s = str(_fv if _fv is not None else '')
            try: SSP_RULE_recognition_method = float(_s) if _s.strip() else _s
            except (ValueError, TypeError): SSP_RULE_recognition_method = _s
        SSP_RULE_ssp_amount = float(get_field_case_insensitive(row, 'SSP_RULE_ssp_amount', 0) or 0)
        _fv = get_field_case_insensitive(row, 'SSP_RULE_standalone_price_policy', '')
        if isinstance(_fv, (int, float)):
            SSP_RULE_standalone_price_policy = _fv
        else:
            _s = str(_fv if _fv is not None else '')
            try: SSP_RULE_standalone_price_policy = float(_s) if _s.strip() else _s
            except (ValueError, TypeError): SSP_RULE_standalone_price_policy = _s
        
        # Execute DSL logic - transactions are created via createTransaction()
        ## ═══════════════════════════════════════════════════════════════
        ## REVREC_REVENUE_RECOGNITION
        ## ═══════════════════════════════════════════════════════════════

        ## Steps
        postingdate = SALE_ORDER_DETAILS_postingdate  # DSL_LINE:6
        effectivedate = SALE_ORDER_DETAILS_postingdate  # DSL_LINE:7
        subinstrumentid = collect_by_instrument('SALE_ORDER_DETAILS_subinstrumentid')  # DSL_LINE:8
        register_ssp = collect_all('SSP_RULE_ssp_amount')  # DSL_LINE:9
        register_balance = collect_by_instrument('REVENUE_BALANCE_BALANCES_ENDINGBALANCE_TOTAL_REVENUE')  # DSL_LINE:10
        cat_product = collect_all('SSP_RULE_product_code')  # DSL_LINE:11
        cat_policy = collect_all('SSP_RULE_standalone_price_policy')  # DSL_LINE:12
        cat_ssp_amount = collect_all('SSP_RULE_ssp_amount')  # DSL_LINE:13
        cat_method = collect_all('SSP_RULE_recognition_method')  # DSL_LINE:14
        line_products = collect_by_instrument('SALE_ORDER_DETAILS_ATTRIBUTE_PRODUCT_ID_CURRENT')  # DSL_LINE:15
        line_sale_prices = collect_by_instrument('SALE_ORDER_DETAILS_ATTRIBUTE_SALE_PRICE_CURRENT')  # DSL_LINE:16
        line_starts = collect_by_instrument('SALE_ORDER_DETAILS_ATTRIBUTE_SERVICE_START_DATE_CURRENT')  # DSL_LINE:17
        line_ends = collect_by_instrument('SALE_ORDER_DETAILS_ATTRIBUTE_SERVICE_END_DATE_CURRENT')  # DSL_LINE:18
        missing_order_terms = iif(eq(array_length(subinstrumentid), 0), 1, 0)  # DSL_LINE:19
        line_postings = collect_by_instrument('SALE_ORDER_DETAILS_postingdate')  # DSL_LINE:20
        bal_subids = collect_by_instrument('REVENUE_BALANCE_subinstrumentid')  # DSL_LINE:21
        bal_amounts = collect_by_instrument('REVENUE_BALANCE_BALANCES_ENDINGBALANCE_TOTAL_REVENUE')  # DSL_LINE:22
        boarding_month_end = collect_by_instrument('SALE_ORDER_DETAILS_ATTRIBUTE_TRANSACTIONDATE_CURRENT')  # DSL_LINE:23
        register_delivery = collect_by_instrument('PROF_SERVICE_DELIVERY_units_delivered')  # DSL_LINE:24
        pdel_subids = collect_by_instrument('PROF_SERVICE_DELIVERY_subinstrumentid')  # DSL_LINE:25
        pdel_units = collect_by_instrument('PROF_SERVICE_DELIVERY_units_delivered')  # DSL_LINE:26
        pdel_postings = collect_by_instrument('PROF_SERVICE_DELIVERY_postingdate')  # DSL_LINE:27
        ## Iteration
        cur_delivery_units = apply_each(subinstrumentid, "sum(multiply(multiply(eq(pdel_subids, each), eq(pdel_postings, postingdate)), pdel_units))", {"postingdate": postingdate, "subinstrumentid": subinstrumentid, "pdel_subids": pdel_subids, "pdel_units": pdel_units, "pdel_postings": pdel_postings})  # DSL_LINE:29

        ## Iteration
        line_policies = apply_each(subinstrumentid, "lookup(cat_policy, cat_product, lookup(line_products, subinstrumentid, each))", {"subinstrumentid": subinstrumentid, "cat_product": cat_product, "cat_policy": cat_policy, "line_products": line_products})  # DSL_LINE:32

        ## Iteration
        line_ssp_dollar = apply_each(subinstrumentid, "lookup(cat_ssp_amount, cat_product, lookup(line_products, subinstrumentid, each))", {"subinstrumentid": subinstrumentid, "cat_product": cat_product, "cat_ssp_amount": cat_ssp_amount, "line_products": line_products})  # DSL_LINE:35

        ## Iteration
        line_methods = apply_each(subinstrumentid, "lookup(cat_method, cat_product, lookup(line_products, subinstrumentid, each))", {"subinstrumentid": subinstrumentid, "cat_product": cat_product, "cat_method": cat_method, "line_products": line_products})  # DSL_LINE:38

        ## Iteration
        line_ssp_raw = apply_each(subinstrumentid, "iif(eq(lookup(line_policies, subinstrumentid, each), \"DOLLAR_AMOUNT\"), lookup(line_ssp_dollar, subinstrumentid, each), lookup(line_sale_prices, subinstrumentid, each))", {"subinstrumentid": subinstrumentid, "line_sale_prices": line_sale_prices, "line_policies": line_policies, "line_ssp_dollar": line_ssp_dollar})  # DSL_LINE:41

        total_ssp_raw = sum(line_ssp_raw)  # DSL_LINE:43
        ## Iteration
        line_ssp_amounts = apply_each(subinstrumentid, "iif(eq(total_ssp_raw, 0), abs(lookup(line_sale_prices, subinstrumentid, each)), lookup(line_ssp_raw, subinstrumentid, each))", {"subinstrumentid": subinstrumentid, "line_sale_prices": line_sale_prices, "line_ssp_raw": line_ssp_raw, "total_ssp_raw": total_ssp_raw})  # DSL_LINE:45

        line_inv = collect_by_instrument('SALE_ORDER_DETAILS_ATTRIBUTE_INVOICE_NUMBER_CURRENT')  # DSL_LINE:47
        line_refinv = collect_by_instrument('SALE_ORDER_DETAILS_ATTRIBUTE_REFERENCE_INVOICE_NUMBER_CURRENT')  # DSL_LINE:48
        ## Iteration
        line_is_credit = apply_each(subinstrumentid, "iif(neq(lookup(line_inv, subinstrumentid, each), lookup(line_refinv, subinstrumentid, each)), 1, iif(lt(lookup(line_sale_prices, subinstrumentid, each), 0), 1, 0))", {"subinstrumentid": subinstrumentid, "line_sale_prices": line_sale_prices, "line_inv": line_inv, "line_refinv": line_refinv})  # DSL_LINE:50

        ## Iteration
        line_sale_price_nc = apply_each(subinstrumentid, "multiply(lookup(line_sale_prices, subinstrumentid, each), subtract(1, lookup(line_is_credit, subinstrumentid, each)))", {"subinstrumentid": subinstrumentid, "line_sale_prices": line_sale_prices, "line_is_credit": line_is_credit})  # DSL_LINE:53

        ## Iteration
        line_ssp_nc = apply_each(subinstrumentid, "multiply(lookup(line_ssp_amounts, subinstrumentid, each), subtract(1, lookup(line_is_credit, subinstrumentid, each)))", {"subinstrumentid": subinstrumentid, "line_ssp_amounts": line_ssp_amounts, "line_is_credit": line_is_credit})  # DSL_LINE:56

        total_sale_price = sum(line_sale_price_nc)  # DSL_LINE:58
        total_ssp = sum(line_ssp_nc)  # DSL_LINE:59
        ## Iteration
        line_ratios = apply_each(subinstrumentid, "iif(eq(total_ssp, 0), 0, divide(lookup(line_ssp_amounts, subinstrumentid, each), total_ssp))", {"subinstrumentid": subinstrumentid, "line_ssp_amounts": line_ssp_amounts, "total_ssp": total_ssp})  # DSL_LINE:61

        ## Iteration
        sub_recip = apply_each(subinstrumentid, "divide(1, sum(eq(subinstrumentid, each)))", {"subinstrumentid": subinstrumentid})  # DSL_LINE:64

        distinct_prod_count = sum(sub_recip)  # DSL_LINE:66
        total_ssp_d = sum(multiply(line_ssp_nc, sub_recip))  # DSL_LINE:67
        credit_pool_d = sum(multiply(multiply(line_sale_prices, line_is_credit), sub_recip))  # DSL_LINE:68
        ## Iteration
        line_base_alloc = apply_each(subinstrumentid, "multiply(lookup(line_ratios, subinstrumentid, each), total_sale_price)", {"subinstrumentid": subinstrumentid, "total_sale_price": total_sale_price, "line_ratios": line_ratios})  # DSL_LINE:70

        ## Iteration
        line_base_alloc_adj = apply_each(subinstrumentid, "lookup(line_base_alloc, subinstrumentid, each)", {"subinstrumentid": subinstrumentid, "line_base_alloc": line_base_alloc})  # DSL_LINE:73

        ## Iteration
        noncredit_product_key = apply_each(subinstrumentid, "iif(eq(lookup(line_is_credit, subinstrumentid, each), 1), \"__CREDIT__\", lookup(line_products, subinstrumentid, each))", {"subinstrumentid": subinstrumentid, "line_products": line_products, "line_is_credit": line_is_credit})  # DSL_LINE:76

        ## Iteration
        credit_pool_line = apply_each(subinstrumentid, "sum(multiply(multiply(multiply(eq(line_inv, lookup(line_inv, subinstrumentid, each)), line_is_credit), line_sale_prices), sub_recip))", {"subinstrumentid": subinstrumentid, "line_sale_prices": line_sale_prices, "line_inv": line_inv, "line_is_credit": line_is_credit, "sub_recip": sub_recip})  # DSL_LINE:79

        ## Iteration
        line_alloc_raw = apply_each(subinstrumentid, "iif(eq(lookup(line_is_credit, subinstrumentid, each), 1), iif(eq(total_ssp_d, 0), lookup(line_sale_prices, subinstrumentid, each), multiply(divide(lookup(line_ssp_amounts, subinstrumentid, each), total_ssp_d), lookup(credit_pool_line, subinstrumentid, each))), lookup(line_base_alloc_adj, subinstrumentid, each))", {"subinstrumentid": subinstrumentid, "line_sale_prices": line_sale_prices, "line_ssp_amounts": line_ssp_amounts, "line_is_credit": line_is_credit, "total_ssp_d": total_ssp_d, "line_base_alloc_adj": line_base_alloc_adj, "credit_pool_line": credit_pool_line})  # DSL_LINE:82

        ## Iteration
        line_alloc_r = apply_each(subinstrumentid, "round(lookup(line_alloc_raw, subinstrumentid, each), 4)", {"subinstrumentid": subinstrumentid, "line_alloc_raw": line_alloc_raw})  # DSL_LINE:85

        total_sale_price_d = sum(multiply(line_sale_price_nc, sub_recip))  # DSL_LINE:87
        alloc_sum_r = sum(multiply(line_alloc_r, sub_recip))  # DSL_LINE:88
        alloc_residual = subtract(add(total_sale_price_d, credit_pool_d), alloc_sum_r)  # DSL_LINE:89
        alloc_max = array_get(line_alloc_r, 0, 0)  # DSL_LINE:90
        alloc_tied = sum(multiply(eq(line_alloc_r, alloc_max), sub_recip))  # DSL_LINE:91
        ## Iteration
        line_allocated = apply_each(subinstrumentid, "add(lookup(line_alloc_r, subinstrumentid, each), iif(eq(alloc_tied, 0), 0, iif(gte(abs(alloc_residual), 0.005), 0, iif(eq(lookup(line_alloc_r, subinstrumentid, each), alloc_max), divide(alloc_residual, alloc_tied), 0))))", {"subinstrumentid": subinstrumentid, "line_alloc_r": line_alloc_r, "alloc_residual": alloc_residual, "alloc_max": alloc_max, "alloc_tied": alloc_tied})  # DSL_LINE:93

        ## Iteration
        line_balance = apply_each(subinstrumentid, "sum(multiply(eq(bal_subids, each), bal_amounts))", {"subinstrumentid": subinstrumentid, "bal_subids": bal_subids, "bal_amounts": bal_amounts})  # DSL_LINE:96

        bal_postings = collect_by_instrument('REVENUE_BALANCE_postingdate')  # DSL_LINE:98
        stale_balance_error = iif(eq(array_length(bal_postings), 0), 0, iif(eq(date_diff_days(array_get(bal_postings, 0, postingdate), postingdate), 0), 0, 1))  # DSL_LINE:99
        ## Iteration
        balance_row_count = apply_each(subinstrumentid, "sum(eq(bal_subids, each))", {"subinstrumentid": subinstrumentid, "bal_subids": bal_subids})  # DSL_LINE:101

        balance_alignment_error = iif(gt(sum(balance_row_count), array_length(bal_subids)), 1, 0)  # DSL_LINE:103
        ## Iteration
        cur_delivery_amount = apply_each(subinstrumentid, "multiply(lookup(cur_delivery_units, subinstrumentid, each), lookup(line_allocated, subinstrumentid, each))", {"subinstrumentid": subinstrumentid, "cur_delivery_units": cur_delivery_units, "line_allocated": line_allocated})  # DSL_LINE:105

        ## Iteration
        line_remaining = apply_each(subinstrumentid, "iif(eq(lookup(line_methods, subinstrumentid, each), \"PROPORTIONAL_PERFORMANCE\"), subtract(add(lookup(line_allocated, subinstrumentid, each), lookup(line_balance, subinstrumentid, each)), lookup(cur_delivery_amount, subinstrumentid, each)), iif(gte(lookup(line_allocated, subinstrumentid, each), 0), max(subtract(lookup(line_allocated, subinstrumentid, each), lookup(line_balance, subinstrumentid, each)), 0), min(subtract(lookup(line_allocated, subinstrumentid, each), lookup(line_balance, subinstrumentid, each)), 0)))", {"subinstrumentid": subinstrumentid, "line_methods": line_methods, "line_allocated": line_allocated, "line_balance": line_balance, "cur_delivery_amount": cur_delivery_amount})  # DSL_LINE:108

        ## Iteration
        line_po_days = apply_each(subinstrumentid, "add(date_diff_days(lookup(line_starts, subinstrumentid, each), lookup(line_ends, subinstrumentid, each)), 1)", {"subinstrumentid": subinstrumentid, "line_starts": line_starts, "line_ends": line_ends})  # DSL_LINE:111

        ## Iteration
        line_per_day = apply_each(subinstrumentid, "iif(eq(lookup(line_po_days, subinstrumentid, each), 0), 0, divide(lookup(line_allocated, subinstrumentid, each), lookup(line_po_days, subinstrumentid, each)))", {"subinstrumentid": subinstrumentid, "line_allocated": line_allocated, "line_po_days": line_po_days})  # DSL_LINE:114

        ## Iteration
        line_is_ratable = apply_each(subinstrumentid, "iif(eq(lookup(line_methods, subinstrumentid, each), \"RATABLE\"), 1, 0)", {"subinstrumentid": subinstrumentid, "line_methods": line_methods})  # DSL_LINE:117

        ## Iteration
        line_is_pit = apply_each(subinstrumentid, "iif(eq(lookup(line_methods, subinstrumentid, each), \"POINT_IN_TIME\"), 1, 0)", {"subinstrumentid": subinstrumentid, "line_methods": line_methods})  # DSL_LINE:120

        ## Iteration
        line_is_prop = apply_each(subinstrumentid, "iif(eq(lookup(line_methods, subinstrumentid, each), \"PROPORTIONAL_PERFORMANCE\"), 1, 0)", {"subinstrumentid": subinstrumentid, "line_methods": line_methods})  # DSL_LINE:123

        ## Iteration
        line_ends_eom = apply_each(subinstrumentid, "end_of_month(lookup(line_ends, subinstrumentid, each))", {"subinstrumentid": subinstrumentid, "line_ends": line_ends})  # DSL_LINE:126

        ## Schedule
        p = period(line_starts, line_ends_eom, "M")  # DSL_LINE:129
        rev_schedule = schedule(p, {  # DSL_LINE:130
        "period_date": "period_date",  # DSL_LINE:131
        "month_end": "end_of_month(period_date)",  # DSL_LINE:132
        "days_in_month": "add(date_diff_days(iif(gt(date_diff_days(start_of_month(month_end), line_starts), 0), line_starts, start_of_month(month_end)), iif(gt(date_diff_days(line_ends, month_end), 0), line_ends, month_end)), 1)",  # DSL_LINE:133
        "period_no": "add(period_index, 1)",  # DSL_LINE:134
        "prior_ltd_days": "date_diff_days(line_starts, start_of_month(month_end))",  # DSL_LINE:135
        "is_last": "iif(eq(date_diff_days(month_end, end_of_month(line_ends)), 0), 1, 0)",  # DSL_LINE:136
        "gross_calc": "iif(eq(line_is_ratable, 1), multiply(line_per_day, days_in_month), iif(eq(line_is_pit, 1), iif(eq(date_diff_days(month_end, end_of_month(line_starts)), 0), line_allocated, 0), iif(eq(line_is_prop, 1), iif(eq(is_last, 1), line_remaining, 0), iif(eq(is_last, 1), line_allocated, 0))))",  # DSL_LINE:137
        "cum_prior": "lag('ltd_gross', 1, 0)",  # DSL_LINE:138
        "gross_revenue": "iif(eq(multiply(is_last, line_is_ratable), 1), subtract(line_allocated, cum_prior), gross_calc)",  # DSL_LINE:139
        "boarding_me": "end_of_month(boarding_month_end)",  # DSL_LINE:140
        "pre_gross": "iif(gt(date_diff_days(month_end, boarding_me), 0), gross_revenue, 0)",  # DSL_LINE:141
        "cum_pre": "add(lag('cum_pre', 1, 0), pre_gross)",  # DSL_LINE:142
        "revenue_ppa": "round(iif(eq(date_diff_days(month_end, boarding_me), 0), lag('cum_pre', 1, 0), 0), 4)",  # DSL_LINE:143
        "revenue": "iif(lte(date_diff_days(month_end, boarding_me), 0), gross_revenue, 0)",  # DSL_LINE:144
        "ltd_gross": "add(lag('ltd_gross', 1, 0), gross_revenue)"  # DSL_LINE:145
        }, {"boarding_month_end": boarding_month_end, "line_allocated": line_allocated, "line_ends": line_ends, "line_is_pit": line_is_pit, "line_is_prop": line_is_prop, "line_is_ratable": line_is_ratable, "line_per_day": line_per_day, "line_remaining": line_remaining, "line_starts": line_starts, "item_names": line_products})  # DSL_LINE:146
        rev_now = schedule_filter(rev_schedule, "month_end", postingdate, "revenue")  # DSL_LINE:147
        ppa_now = schedule_filter(rev_schedule, "month_end", postingdate, "revenue_ppa")  # DSL_LINE:148
        posted_rev_total = schedule_sum(rev_schedule, "revenue")  # DSL_LINE:149
        ltd_close = schedule_last(rev_schedule, "ltd_gross")  # DSL_LINE:150

        ## Iteration
        ppa_amount = apply_each(subinstrumentid, "round(lookup(ppa_now, subinstrumentid, each), 4)", {"subinstrumentid": subinstrumentid, "ppa_now": ppa_now})  # DSL_LINE:153

        ## Iteration
        late_credit_ppa = apply_each(subinstrumentid, "iif(gt(multiply(gt(date_diff_days(end_of_month(lookup(line_ends, subinstrumentid, each)), end_of_month(lookup(boarding_month_end, subinstrumentid, each))), 0), eq(date_diff_days(end_of_month(postingdate), end_of_month(lookup(boarding_month_end, subinstrumentid, each))), 0)), 0), lookup(line_allocated, subinstrumentid, each), 0)", {"postingdate": postingdate, "subinstrumentid": subinstrumentid, "line_ends": line_ends, "boarding_month_end": boarding_month_end, "line_allocated": line_allocated})  # DSL_LINE:156

        ## Iteration
        rev_amount = apply_each(subinstrumentid, "iif(gt(multiply(multiply(eq(lookup(line_is_ratable, subinstrumentid, each), 1), eq(date_diff_days(end_of_month(postingdate), end_of_month(lookup(line_ends, subinstrumentid, each))), 0)), gt(array_length(bal_subids), 0)), 0), subtract(add(lookup(line_allocated, subinstrumentid, each), lookup(line_balance, subinstrumentid, each)), lookup(ppa_amount, subinstrumentid, each)), lookup(rev_now, subinstrumentid, each))", {"postingdate": postingdate, "subinstrumentid": subinstrumentid, "line_ends": line_ends, "bal_subids": bal_subids, "line_allocated": line_allocated, "line_balance": line_balance, "line_is_ratable": line_is_ratable, "rev_now": rev_now, "ppa_amount": ppa_amount})  # DSL_LINE:159

        recon_difference = subtract(posted_rev_total, line_allocated)  # DSL_LINE:161
        ## Iteration
        per_line_credit_err = apply_each(subinstrumentid, "iif(eq(lookup(line_is_credit, subinstrumentid, each), 1), iif(gt(abs(add(lookup(line_sale_prices, subinstrumentid, each), lookup(line_sale_prices, noncredit_product_key, lookup(line_products, subinstrumentid, each)))), 0.005), 1, 0), 0)", {"subinstrumentid": subinstrumentid, "line_products": line_products, "line_sale_prices": line_sale_prices, "line_is_credit": line_is_credit, "noncredit_product_key": noncredit_product_key})  # DSL_LINE:163

        credit_amount_error = iif(gt(sum(per_line_credit_err), 0), 1, 0)  # DSL_LINE:165
        ## Iteration
        ratable_adj_ppa = apply_each(subinstrumentid, "iif(gt(multiply(multiply(multiply(eq(lookup(line_is_ratable, subinstrumentid, each), 1), eq(date_diff_days(end_of_month(postingdate), end_of_month(lookup(line_ends, subinstrumentid, each))), 0)), gt(array_length(bal_subids), 0)), gt(abs(subtract(subtract(add(lookup(line_allocated, subinstrumentid, each), lookup(line_balance, subinstrumentid, each)), lookup(rev_amount, subinstrumentid, each)), lookup(ppa_amount, subinstrumentid, each))), 0.005)), 0), subtract(subtract(add(lookup(line_allocated, subinstrumentid, each), lookup(line_balance, subinstrumentid, each)), lookup(rev_amount, subinstrumentid, each)), lookup(ppa_amount, subinstrumentid, each)), 0)", {"postingdate": postingdate, "subinstrumentid": subinstrumentid, "line_ends": line_ends, "bal_subids": bal_subids, "line_allocated": line_allocated, "line_balance": line_balance, "line_is_ratable": line_is_ratable, "ppa_amount": ppa_amount, "rev_amount": rev_amount})  # DSL_LINE:167

        ## Iteration
        ppa_amount_neg = apply_each(subinstrumentid, "round(multiply(add(add(lookup(ppa_amount, subinstrumentid, each), lookup(late_credit_ppa, subinstrumentid, each)), lookup(ratable_adj_ppa, subinstrumentid, each)), -1), 4)", {"subinstrumentid": subinstrumentid, "ppa_amount": ppa_amount, "late_credit_ppa": late_credit_ppa, "ratable_adj_ppa": ratable_adj_ppa})  # DSL_LINE:170

        ## Iteration
        rev_amount_neg = apply_each(subinstrumentid, "round(multiply(lookup(rev_amount, subinstrumentid, each), -1), 4)", {"subinstrumentid": subinstrumentid, "rev_amount": rev_amount})  # DSL_LINE:173

        ## Iteration
        alloc_booked = apply_each(subinstrumentid, "iif(eq(date_diff_days(end_of_month(postingdate), end_of_month(lookup(boarding_month_end, subinstrumentid, each))), 0), lookup(line_allocated, subinstrumentid, each), 0)", {"postingdate": postingdate, "subinstrumentid": subinstrumentid, "boarding_month_end": boarding_month_end, "line_allocated": line_allocated})  # DSL_LINE:176

        alloc_residual_error = iif(gt(abs(alloc_residual), 0.005), 1, 0)  # DSL_LINE:178

        ## Create Transactions
        createTransaction(postingdate, effectivedate, "Revenue", rev_amount_neg, subinstrumentid)  # DSL_LINE:181
        createTransaction(postingdate, effectivedate, "Revenue_PPA", ppa_amount_neg, subinstrumentid)  # DSL_LINE:182
        createTransaction(postingdate, effectivedate, "ALLOCATED_REVENUE", alloc_booked, subinstrumentid)  # DSL_LINE:183

        ## ═══════════════════════════════════════════════════════════════
        ## REVREC_PROPORTIONAL_DELIVERY
        ## ═══════════════════════════════════════════════════════════════

        ## Steps
        postingdate = PROF_SERVICE_DELIVERY_postingdate  # DSL_LINE:190
        effectivedate = PROF_SERVICE_DELIVERY_postingdate  # DSL_LINE:191
        delivery_effdate = PROF_SERVICE_DELIVERY_effectivedate  # DSL_LINE:192
        subinstrumentid = PROF_SERVICE_DELIVERY_subinstrumentid  # DSL_LINE:193
        this_sub = PROF_SERVICE_DELIVERY_subinstrumentid  # DSL_LINE:194
        units = PROF_SERVICE_DELIVERY_units_delivered  # DSL_LINE:195
        concat_key = concat(instrumentid, this_sub)  # DSL_LINE:196
        pdel_ids = collect_by_instrument('PROF_SERVICE_DELIVERY_service_delivery_id')  # DSL_LINE:197
        pdel_subids = collect_by_instrument('PROF_SERVICE_DELIVERY_subinstrumentid')  # DSL_LINE:198
        pdel_units = collect_by_instrument('PROF_SERVICE_DELIVERY_units_delivered')  # DSL_LINE:199
        pdel_postings = collect_by_instrument('PROF_SERVICE_DELIVERY_postingdate')  # DSL_LINE:200
        pdel_effdates = collect_by_instrument('PROF_SERVICE_DELIVERY_effectivedate')  # DSL_LINE:201
        line_ends = collect_by_instrument('SALE_ORDER_DETAILS_ATTRIBUTE_SERVICE_END_DATE_CURRENT')  # DSL_LINE:202
        order_end = max(line_ends)  # DSL_LINE:203
        register_balance = collect_by_instrument('REVENUE_BALANCE_BALANCES_ENDINGBALANCE_TOTAL_REVENUE')  # DSL_LINE:204
        bal_subids = collect_by_instrument('REVENUE_BALANCE_subinstrumentid')  # DSL_LINE:205
        bal_amounts = collect_by_instrument('REVENUE_BALANCE_BALANCES_ENDINGBALANCE_TOTAL_REVENUE')  # DSL_LINE:206
        register_ssp = collect_all('SSP_RULE_ssp_amount')  # DSL_LINE:207
        register_so = collect_by_instrument('SALE_ORDER_DETAILS_ATTRIBUTE_SALE_PRICE_CURRENT')  # DSL_LINE:208
        cat_product = collect_all('SSP_RULE_product_code')  # DSL_LINE:209
        cat_policy = collect_all('SSP_RULE_standalone_price_policy')  # DSL_LINE:210
        cat_ssp_amount = collect_all('SSP_RULE_ssp_amount')  # DSL_LINE:211
        line_products = collect_by_instrument('SALE_ORDER_DETAILS_ATTRIBUTE_PRODUCT_ID_CURRENT')  # DSL_LINE:212
        line_sub_ids = collect_by_instrument('SALE_ORDER_DETAILS_subinstrumentid')  # DSL_LINE:213
        line_sale_prices = collect_by_instrument('SALE_ORDER_DETAILS_ATTRIBUTE_SALE_PRICE_CURRENT')  # DSL_LINE:214
        line_postings = collect_by_instrument('SALE_ORDER_DETAILS_postingdate')  # DSL_LINE:215
        boarding_month_end = end_of_month(array_get(line_postings, 0, postingdate))  # DSL_LINE:216
        ## Iteration
        line_policies = apply_each(line_products, "lookup(cat_policy, cat_product, each)", {"cat_product": cat_product, "cat_policy": cat_policy, "line_products": line_products})  # DSL_LINE:218

        ## Iteration
        line_ssp_dollar = apply_each(line_products, "lookup(cat_ssp_amount, cat_product, each)", {"cat_product": cat_product, "cat_ssp_amount": cat_ssp_amount, "line_products": line_products})  # DSL_LINE:221

        ## Iteration
        line_ssp_amounts = apply_each(line_products, "iif(eq(lookup(line_policies, line_products, each), \"DOLLAR_AMOUNT\"), lookup(line_ssp_dollar, line_products, each), lookup(line_sale_prices, line_products, each))", {"line_products": line_products, "line_sale_prices": line_sale_prices, "line_policies": line_policies, "line_ssp_dollar": line_ssp_dollar})  # DSL_LINE:224

        line_inv = collect_by_instrument('SALE_ORDER_DETAILS_ATTRIBUTE_INVOICE_NUMBER_CURRENT')  # DSL_LINE:226
        line_refinv = collect_by_instrument('SALE_ORDER_DETAILS_ATTRIBUTE_REFERENCE_INVOICE_NUMBER_CURRENT')  # DSL_LINE:227
        ## Iteration
        line_is_credit = apply_each(line_sub_ids, "iif(neq(lookup(line_inv, line_sub_ids, each), lookup(line_refinv, line_sub_ids, each)), 1, 0)", {"line_sub_ids": line_sub_ids, "line_inv": line_inv, "line_refinv": line_refinv})  # DSL_LINE:229

        ## Iteration
        line_sale_price_nc = apply_each(line_sub_ids, "multiply(lookup(line_sale_prices, line_sub_ids, each), subtract(1, lookup(line_is_credit, line_sub_ids, each)))", {"line_sub_ids": line_sub_ids, "line_sale_prices": line_sale_prices, "line_is_credit": line_is_credit})  # DSL_LINE:232

        ## Iteration
        line_ssp_nc = apply_each(line_sub_ids, "multiply(lookup(line_ssp_amounts, line_sub_ids, each), subtract(1, lookup(line_is_credit, line_sub_ids, each)))", {"line_sub_ids": line_sub_ids, "line_ssp_amounts": line_ssp_amounts, "line_is_credit": line_is_credit})  # DSL_LINE:235

        total_sale_price = sum(line_sale_price_nc)  # DSL_LINE:237
        total_ssp = sum(line_ssp_nc)  # DSL_LINE:238
        ## Iteration
        line_ratios = apply_each(line_sub_ids, "iif(eq(total_ssp, 0), 0, divide(lookup(line_ssp_amounts, line_sub_ids, each), total_ssp))", {"line_sub_ids": line_sub_ids, "line_ssp_amounts": line_ssp_amounts, "total_ssp": total_ssp})  # DSL_LINE:240

        ## Iteration
        sub_recip = apply_each(line_sub_ids, "divide(1, sum(eq(line_sub_ids, each)))", {"line_sub_ids": line_sub_ids})  # DSL_LINE:243

        distinct_prod_count = sum(sub_recip)  # DSL_LINE:245
        ## Iteration
        line_base_alloc = apply_each(line_sub_ids, "round(multiply(lookup(line_ratios, line_sub_ids, each), total_sale_price), 4)", {"line_sub_ids": line_sub_ids, "total_sale_price": total_sale_price, "line_ratios": line_ratios})  # DSL_LINE:247

        ## Iteration
        line_base_alloc_adj = apply_each(line_sub_ids, "iif(gt(multiply(multiply(eq(total_ssp, 0), eq(distinct_prod_count, 1)), eq(lookup(line_ssp_amounts, line_sub_ids, each), 0)), 0), lookup(line_sale_prices, line_sub_ids, each), lookup(line_base_alloc, line_sub_ids, each))", {"line_sub_ids": line_sub_ids, "line_sale_prices": line_sale_prices, "line_ssp_amounts": line_ssp_amounts, "total_ssp": total_ssp, "distinct_prod_count": distinct_prod_count, "line_base_alloc": line_base_alloc})  # DSL_LINE:250

        ## Iteration
        noncredit_product_key = apply_each(line_sub_ids, "iif(eq(lookup(line_is_credit, line_sub_ids, each), 1), \"__CREDIT__\", lookup(line_products, line_sub_ids, each))", {"line_products": line_products, "line_sub_ids": line_sub_ids, "line_is_credit": line_is_credit})  # DSL_LINE:253

        ## Iteration
        line_allocated = apply_each(line_sub_ids, "iif(eq(lookup(line_is_credit, line_sub_ids, each), 1), subtract(0, lookup(line_base_alloc_adj, noncredit_product_key, lookup(line_products, line_sub_ids, each))), lookup(line_base_alloc_adj, line_sub_ids, each))", {"line_products": line_products, "line_sub_ids": line_sub_ids, "line_is_credit": line_is_credit, "line_base_alloc_adj": line_base_alloc_adj, "noncredit_product_key": noncredit_product_key})  # DSL_LINE:256

        allocated_for_line = lookup(line_allocated, line_sub_ids, this_sub)  # DSL_LINE:258
        delivery_amount = round(multiply(units, allocated_for_line), 4)  # DSL_LINE:259
        delivery_ppa = iif(gt(date_diff_days(end_of_month(delivery_effdate), end_of_month(postingdate)), 0), delivery_amount, 0)  # DSL_LINE:260
        delivery_revenue = iif(lte(date_diff_days(end_of_month(delivery_effdate), end_of_month(postingdate)), 0), delivery_amount, 0)  # DSL_LINE:261
        ## Iteration
        pdel_days = apply_each(pdel_ids, "date_diff_days(lookup(pdel_postings, pdel_ids, each), postingdate)", {"postingdate": postingdate, "pdel_ids": pdel_ids, "pdel_postings": pdel_postings})  # DSL_LINE:263

        ## Iteration
        pdel_term_days = apply_each(pdel_ids, "date_diff_days(lookup(pdel_postings, pdel_ids, each), lookup(line_ends, line_sub_ids, lookup(pdel_subids, pdel_ids, each)))", {"pdel_ids": pdel_ids, "pdel_subids": pdel_subids, "pdel_postings": pdel_postings, "line_ends": line_ends, "line_sub_ids": line_sub_ids})  # DSL_LINE:266

        ## Iteration
        del_cum_incl = apply_each(pdel_ids, "sum(multiply(multiply(multiply(eq(pdel_subids, lookup(pdel_subids, pdel_ids, each)), gte(pdel_term_days, 0)), gte(pdel_days, 0)), pdel_units))", {"pdel_ids": pdel_ids, "pdel_subids": pdel_subids, "pdel_units": pdel_units, "pdel_days": pdel_days, "pdel_term_days": pdel_term_days})  # DSL_LINE:269

        ## Iteration
        del_cum_prior = apply_each(pdel_ids, "sum(multiply(multiply(multiply(eq(pdel_subids, lookup(pdel_subids, pdel_ids, each)), gte(pdel_term_days, 0)), gt(pdel_days, 0)), pdel_units))", {"pdel_ids": pdel_ids, "pdel_subids": pdel_subids, "pdel_units": pdel_units, "pdel_days": pdel_days, "pdel_term_days": pdel_term_days})  # DSL_LINE:272

        ## Iteration
        del_n_logs = apply_each(pdel_ids, "iif(lt(sum(multiply(multiply(eq(pdel_subids, lookup(pdel_subids, pdel_ids, each)), gte(pdel_term_days, 0)), eq(pdel_days, 0))), 1), 1, sum(multiply(multiply(eq(pdel_subids, lookup(pdel_subids, pdel_ids, each)), gte(pdel_term_days, 0)), eq(pdel_days, 0))))", {"pdel_ids": pdel_ids, "pdel_subids": pdel_subids, "pdel_days": pdel_days, "pdel_term_days": pdel_term_days})  # DSL_LINE:275

        ## Iteration
        del_amount = apply_each(pdel_ids, "round(multiply(iif(gt(multiply(lookup(pdel_units, pdel_ids, each), lookup(line_allocated, line_sub_ids, lookup(pdel_subids, pdel_ids, each))), iif(lt(add(lookup(line_allocated, line_sub_ids, lookup(pdel_subids, pdel_ids, each)), sum(multiply(eq(bal_subids, lookup(pdel_subids, pdel_ids, each)), bal_amounts))), 0), 0, add(lookup(line_allocated, line_sub_ids, lookup(pdel_subids, pdel_ids, each)), sum(multiply(eq(bal_subids, lookup(pdel_subids, pdel_ids, each)), bal_amounts))))), iif(lt(add(lookup(line_allocated, line_sub_ids, lookup(pdel_subids, pdel_ids, each)), sum(multiply(eq(bal_subids, lookup(pdel_subids, pdel_ids, each)), bal_amounts))), 0), 0, add(lookup(line_allocated, line_sub_ids, lookup(pdel_subids, pdel_ids, each)), sum(multiply(eq(bal_subids, lookup(pdel_subids, pdel_ids, each)), bal_amounts)))), multiply(lookup(pdel_units, pdel_ids, each), lookup(line_allocated, line_sub_ids, lookup(pdel_subids, pdel_ids, each)))), iif(eq(lookup(pdel_postings, pdel_ids, each), postingdate), 1, 0)), 4)", {"postingdate": postingdate, "pdel_ids": pdel_ids, "pdel_subids": pdel_subids, "pdel_units": pdel_units, "pdel_postings": pdel_postings, "bal_subids": bal_subids, "bal_amounts": bal_amounts, "line_sub_ids": line_sub_ids, "line_allocated": line_allocated})  # DSL_LINE:278

        ## Iteration
        del_ispast = apply_each(pdel_ids, "iif(gt(date_diff_days(end_of_month(lookup(pdel_effdates, pdel_ids, each)), end_of_month(postingdate)), 0), 1, 0)", {"postingdate": postingdate, "pdel_ids": pdel_ids, "pdel_effdates": pdel_effdates})  # DSL_LINE:281

        ## Iteration
        del_subs = apply_each(pdel_ids, "lookup(pdel_subids, pdel_ids, each)", {"pdel_ids": pdel_ids, "pdel_subids": pdel_subids})  # DSL_LINE:284

        ## Iteration
        del_ppa_neg = apply_each(pdel_ids, "multiply(multiply(lookup(del_amount, pdel_ids, each), lookup(del_ispast, pdel_ids, each)), -1)", {"pdel_ids": pdel_ids, "del_amount": del_amount, "del_ispast": del_ispast})  # DSL_LINE:287

        ## Iteration
        del_rev_neg = apply_each(pdel_ids, "multiply(multiply(lookup(del_amount, pdel_ids, each), subtract(1, lookup(del_ispast, pdel_ids, each))), -1)", {"pdel_ids": pdel_ids, "del_amount": del_amount, "del_ispast": del_ispast})  # DSL_LINE:290

        del_amt_row = round(iif(gt(multiply(units, allocated_for_line), iif(lt(add(allocated_for_line, sum(multiply(eq(bal_subids, this_sub), bal_amounts))), 0), 0, add(allocated_for_line, sum(multiply(eq(bal_subids, this_sub), bal_amounts))))), iif(lt(add(allocated_for_line, sum(multiply(eq(bal_subids, this_sub), bal_amounts))), 0), 0, add(allocated_for_line, sum(multiply(eq(bal_subids, this_sub), bal_amounts)))), multiply(units, allocated_for_line)), 4)  # DSL_LINE:292
        del_rev_row_neg = iif(lte(date_diff_days(end_of_month(delivery_effdate), end_of_month(postingdate)), 0), multiply(del_amt_row, -1), 0)  # DSL_LINE:293
        del_ppa_row_neg = iif(gt(date_diff_days(end_of_month(delivery_effdate), end_of_month(postingdate)), 0), multiply(del_amt_row, -1), 0)  # DSL_LINE:294

        ## Create Transactions
        createTransaction(postingdate, effectivedate, "Revenue", del_rev_neg, subinstrumentid)  # DSL_LINE:297
        createTransaction(postingdate, effectivedate, "Revenue_PPA", del_ppa_neg, subinstrumentid)  # DSL_LINE:298

        ## ═══════════════════════════════════════════════════════════════
        ## REVREC_BILLING
        ## ═══════════════════════════════════════════════════════════════

        ## Steps
        postingdate = BILLING_SCHEDULE_postingdate  # DSL_LINE:305
        effectivedate = BILLING_SCHEDULE_effectivedate  # DSL_LINE:306
        subinstrumentid = collect_by_instrument('BILLING_SCHEDULE_subinstrumentid')  # DSL_LINE:307
        billing_amount = collect_by_instrument('BILLING_SCHEDULE_billing_amount')  # DSL_LINE:308

        ## Create Transactions
        createTransaction(postingdate, effectivedate, "NEW_BILLING", billing_amount, subinstrumentid)  # DSL_LINE:311
    
    # Get all transactions created via createTransaction()
    results = _get_transaction_results()
    return results
