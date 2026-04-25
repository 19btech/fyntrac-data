

import sys, os
# Ensure backend package folder is on path so imports work when executed from different cwd
ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__)))
if ROOT_DIR not in sys.path:
    sys.path.insert(0, ROOT_DIR)
try:
    from backend.dsl_functions import DSL_FUNCTIONS, _set_current_instrumentid, _set_current_postingdate, _clear_transaction_results, _get_transaction_results, _set_dsl_print
except Exception:
    from dsl_functions import DSL_FUNCTIONS, _set_current_instrumentid, _set_current_postingdate, _clear_transaction_results, _get_transaction_results, _set_dsl_print
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
    current_instrument = _current_context.get('instrumentid', '')

    # Parse field_name
    parts = field_name.split('_', 1)
    if len(parts) == 2:
        event_name, actual_field = parts[0], parts[1]
    else:
        event_name, actual_field = None, field_name

    for evt_name, rows in _raw_event_data.items():
        if event_name and evt_name.upper() != event_name.upper():
            continue

        for row in rows:
            row_instrument = get_field_case_insensitive(row, 'instrumentid', '')

            if row_instrument == current_instrument:
                val = get_field_case_insensitive(row, actual_field, None)
                if val is None:
                    val = get_field_case_insensitive(row, field_name, None)
                # Always emit a row per subinstrument so parallel arrays stay
                # index-aligned. Type-aware placeholder is decided after the
                # scan so dates/strings don't get coerced to 0.
                sub = get_field_case_insensitive(row, 'subinstrumentid', '') or ''
                pairs.append((str(sub), val))

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
    null_placeholder = 0 if (has_value and all_numeric) else ''

    converted = []
    for s, v in pairs:
        if v is None or v == '':
            converted.append((s, null_placeholder))
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

    # Parse field_name
    parts = field_name.split('_', 1)
    if len(parts) == 2:
        event_name, actual_field = parts[0], parts[1]
    else:
        event_name, actual_field = None, field_name

    for evt_name, rows in _raw_event_data.items():
        if event_name and evt_name.upper() != event_name.upper():
            continue

        for idx, row in enumerate(rows):
            val = get_field_case_insensitive(row, actual_field, None)
            if val is None:
                val = get_field_case_insensitive(row, field_name, None)
            # Always emit a row so parallel collect_all() arrays stay
            # index-aligned. Type-aware placeholder is decided after scan.
            sub = get_field_case_insensitive(row, 'subinstrumentid', '') or ''
            pairs.append((str(sub), idx, val))

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
    null_placeholder = 0 if (has_value and all_numeric) else ''

    converted = []
    for s, i, v in pairs:
        if v is None or v == '':
            converted.append((s, i, null_placeholder))
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
    current_instrument = _current_context.get('instrumentid', '')
    current_subinstrument = _current_context.get('subinstrumentid', '1')
    
    # Parse field_name
    parts = field_name.split('_', 1)
    if len(parts) == 2:
        event_name, actual_field = parts[0], parts[1]
    else:
        event_name, actual_field = None, field_name
    
    for evt_name, rows in _raw_event_data.items():
        if event_name and evt_name.upper() != event_name.upper():
            continue
            
        for row in rows:
            row_instrument = get_field_case_insensitive(row, 'instrumentid', '')
            row_subinstrument = get_field_case_insensitive(row, 'subinstrumentid', '1') or '1'
            
            if row_instrument == current_instrument and row_subinstrument == current_subinstrument:
                val = get_field_case_insensitive(row, actual_field, None)
                if val is None:
                    val = get_field_case_insensitive(row, field_name, None)
                if val is not None and val != '':
                    try:
                        values.append(float(val))
                    except (ValueError, TypeError):
                        # For non-numeric values, store as string
                        values.append(val)
    return values

def collect_subinstrumentids():
    """
    Collect all unique subInstrumentIds for the current instrumentId.
    Returns list of subInstrumentId values.
    """
    current_instrument = _current_context.get('instrumentid', '')
    subinstrument_ids = set()
    
    for evt_name, rows in _raw_event_data.items():
        for row in rows:
            row_instrument = get_field_case_insensitive(row, 'instrumentid', '')
            if row_instrument == current_instrument:
                subinstrument = get_field_case_insensitive(row, 'subinstrumentid', '1') or '1'
                subinstrument_ids.add(subinstrument)
    
    return sorted(list(subinstrument_ids))

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
        # Set current postingdate so print_schedule() can tag emitted rows
        # with (_instrumentid, _postingdate) for the Business Preview filter.
        _set_current_postingdate(postingdate)
        
        # Set current context for collect() filtering
        set_current_context(instrumentid, postingdate, effectivedate, subinstrumentid)
        
        # Extract fields from all events with proper datatype conversion
        # Fields from EOD (activity)
        EOD_postingdate = str(get_field_case_insensitive(row, 'EOD_postingdate', ''))
        EOD_effectivedate = str(get_field_case_insensitive(row, 'EOD_effectivedate', ''))
        EOD_subinstrumentid = str(get_field_case_insensitive(row, 'EOD_subinstrumentid', '1'))
        EOD_BALANCES_BEGINNINGBALANCE_REVENUE = float(get_field_case_insensitive(row, 'EOD_BALANCES_BEGINNINGBALANCE_REVENUE', 0) or 0)
        EOD_BALANCES_ENDINGBALANCE_REVENUE = float(get_field_case_insensitive(row, 'EOD_BALANCES_ENDINGBALANCE_REVENUE', 0) or 0)
        EOD_BALANCES_BEGINNINGBALANCE_DEFERRED_REVENUE = float(get_field_case_insensitive(row, 'EOD_BALANCES_BEGINNINGBALANCE_DEFERRED_REVENUE', 0) or 0)
        EOD_BALANCES_ACTIVITY_DEFERRED_REVENUE = float(get_field_case_insensitive(row, 'EOD_BALANCES_ACTIVITY_DEFERRED_REVENUE', 0) or 0)
        EOD_BALANCES_ACTIVITY_REVENUE = float(get_field_case_insensitive(row, 'EOD_BALANCES_ACTIVITY_REVENUE', 0) or 0)
        EOD_BALANCES_ENDINGBALANCE_DEFERRED_REVENUE = float(get_field_case_insensitive(row, 'EOD_BALANCES_ENDINGBALANCE_DEFERRED_REVENUE', 0) or 0)
        EOD_BALANCES_BEGINNINGBALANCE_BILLING = float(get_field_case_insensitive(row, 'EOD_BALANCES_BEGINNINGBALANCE_BILLING', 0) or 0)
        EOD_BALANCES_ACTIVITY_UNBILLED = float(get_field_case_insensitive(row, 'EOD_BALANCES_ACTIVITY_UNBILLED', 0) or 0)
        EOD_BALANCES_ENDINGBALANCE_UNBILLED = float(get_field_case_insensitive(row, 'EOD_BALANCES_ENDINGBALANCE_UNBILLED', 0) or 0)
        EOD_BALANCES_BEGINNINGBALANCE_UNBILLED = float(get_field_case_insensitive(row, 'EOD_BALANCES_BEGINNINGBALANCE_UNBILLED', 0) or 0)
        EOD_BALANCES_ENDINGBALANCE_BILLING = float(get_field_case_insensitive(row, 'EOD_BALANCES_ENDINGBALANCE_BILLING', 0) or 0)
        EOD_BALANCES_ACTIVITY_BILLING = float(get_field_case_insensitive(row, 'EOD_BALANCES_ACTIVITY_BILLING', 0) or 0)
        # Fields from REV (activity)
        REV_postingdate = str(get_field_case_insensitive(row, 'REV_postingdate', ''))
        REV_effectivedate = str(get_field_case_insensitive(row, 'REV_effectivedate', ''))
        REV_subinstrumentid = str(get_field_case_insensitive(row, 'REV_subinstrumentid', '1'))
        REV_ATTRIBUTE_PRODUCT_ID_CURRENT = float(get_field_case_insensitive(row, 'REV_ATTRIBUTE_PRODUCT_ID_CURRENT', 0) or 0)
        REV_ATTRIBUTE_SALE_PRICE_CURRENT = float(get_field_case_insensitive(row, 'REV_ATTRIBUTE_SALE_PRICE_CURRENT', 0) or 0)
        REV_ATTRIBUTE_ITEM_ENDDATE_CURRENT = str(get_field_case_insensitive(row, 'REV_ATTRIBUTE_ITEM_ENDDATE_CURRENT', ''))
        REV_ATTRIBUTE_ITEM_STARTDATE_CURRENT = str(get_field_case_insensitive(row, 'REV_ATTRIBUTE_ITEM_STARTDATE_CURRENT', ''))
        REV_ATTRIBUTE_QUANTITY_CURRENT = float(get_field_case_insensitive(row, 'REV_ATTRIBUTE_QUANTITY_CURRENT', 0) or 0)
        # Fields from CATALOG (reference)
        CATALOG_SSP = str(get_field_case_insensitive(row, 'CATALOG_SSP', ''))
        CATALOG_ProductName = str(get_field_case_insensitive(row, 'CATALOG_ProductName', ''))
        CATALOG_Amount = float(get_field_case_insensitive(row, 'CATALOG_Amount', 0) or 0)
        CATALOG_ProductId = float(get_field_case_insensitive(row, 'CATALOG_ProductId', 0) or 0)
        CATALOG_RevRec_Method = str(get_field_case_insensitive(row, 'CATALOG_RevRec_Method', ''))
        
        # Execute DSL logic - transactions are created via createTransaction()
        ## ═══════════════════════════════════════════════════════════════
        ## STAGE1 - REVENUE ALLOCATION
        ## ═══════════════════════════════════════════════════════════════

        ## Dependencies from saved rules
        ## Steps
        catalog_ids = collect_all('CATALOG_ProductId')  # DSL_LINE:7
        print("catalog_ids =", catalog_ids)  # DSL_LINE:8
        catalog_name = collect_all('CATALOG_ProductName')  # DSL_LINE:9
        print("catalog_name =", catalog_name)  # DSL_LINE:10
        product_id = collect_by_instrument('REV_ATTRIBUTE_PRODUCT_ID_CURRENT')  # DSL_LINE:11
        print("product_id =", product_id)  # DSL_LINE:12
        product_names = lookup(catalog_name,catalog_ids,product_id)  # DSL_LINE:13
        print("product_names =", product_names)  # DSL_LINE:14
        sale_price = collect_by_instrument('REV_ATTRIBUTE_SALE_PRICE_CURRENT')  # DSL_LINE:15
        print("sale_price =", sale_price)  # DSL_LINE:16
        quantity = collect_by_instrument('REV_ATTRIBUTE_QUANTITY_CURRENT')  # DSL_LINE:17
        print("quantity =", quantity)  # DSL_LINE:18
        esp_values = multiply(sale_price, quantity)  # DSL_LINE:19
        print("esp_values =", esp_values)  # DSL_LINE:20
        ## Iteration
        SSP = apply_each(product_names, "iif(eq_ignore_case(each, 'discount'), 0, array_get(esp_values, index, 0))", {"product_names": product_names, "esp_values": esp_values})  # DSL_LINE:22
        print("SSP =", SSP)  # DSL_LINE:23

        subinstrument_ids = collect_by_instrument('REV_subinstrumentid')  # DSL_LINE:25
        print("subinstrument_ids =", subinstrument_ids)  # DSL_LINE:26
        totalssp = sum(SSP)  # DSL_LINE:27
        print("totalssp =", totalssp)  # DSL_LINE:28
        totalesp = sum(esp_values)  # DSL_LINE:29
        print("totalesp =", totalesp)  # DSL_LINE:30
        ## Iteration
        ratio = apply_each(SSP, "divide(each,totalssp)", {"SSP": SSP, "totalssp": totalssp})  # DSL_LINE:32
        print("ratio =", ratio)  # DSL_LINE:33

        ## Iteration
        allocation = apply_each(ratio, "multiply(each,totalesp)", {"totalesp": totalesp, "ratio": ratio})  # DSL_LINE:36
        print("allocation =", allocation)  # DSL_LINE:37


        ## ═══════════════════════════════════════════════════════════════
        ## STAGE 2 - REVENUE SCHEDULE
        ## ═══════════════════════════════════════════════════════════════

        ## Dependencies from saved rules
        ## Steps
        start_dates = collect_by_instrument('REV_ATTRIBUTE_ITEM_STARTDATE_CURRENT')  # DSL_LINE:46
        print("start_dates =", start_dates)  # DSL_LINE:47
        end_dates = collect_by_instrument('REV_ATTRIBUTE_ITEM_ENDDATE_CURRENT')  # DSL_LINE:48
        print("end_dates =", end_dates)  # DSL_LINE:49
        posting_date = REV_postingdate  # DSL_LINE:50
        print("posting_date =", posting_date)  # DSL_LINE:51
        ## Schedule
        p = period(start_dates, end_dates, "M")  # DSL_LINE:53
        Schedule = schedule(p, {  # DSL_LINE:54
        "period_date": "period_date",  # DSL_LINE:55
        "month_end": "end_of_month(period_date)",  # DSL_LINE:56
        "days": "iif(eq(start_date, end_date), add(days_between(start_of_month(period_date), end_of_month(period_date)), 1), iif(eq(period_index, 0), days_between(start_date, end_of_month(start_date)), iif(eq(period_index, subtract(total_periods, 1)), add(days_between(start_of_month(end_date), end_date), 1), add(days_between(start_of_month(period_date), end_of_month(period_date)), 1))))",  # DSL_LINE:57
        "LTD_days": "iif(eq(start_date, end_date), add(days_between(start_of_month(start_date), end_of_month(end_date)), 1), iif(eq(period_date, end_date), days_between(start_date, end_date), days_between(start_date, end_of_month(period_date))))",  # DSL_LINE:58
        "daily_revenue": "iif(eq(start_date, end_date), divide(allocation, days), divide(allocation, 365))",  # DSL_LINE:59
        "period_revenue": "multiply(multiply(daily_revenue, days), -1)",  # DSL_LINE:60
        "LTD_revenue": "multiply(iif(lt(period_date, subtract_months(posting_date, 1)), multiply(daily_revenue, days), 0), -1)"  # DSL_LINE:61
        }, {"allocation": allocation, "posting_date": posting_date})  # DSL_LINE:62
        print(Schedule)  # DSL_LINE:63
        recognition_results_LTD = schedule_sum(Schedule, "LTD_revenue")  # DSL_LINE:64
        recognition_results = schedule_filter(Schedule, "month_end", posting_date, "period_revenue")  # DSL_LINE:65

        EOD_REVENUE = collect_by_instrument('EOD_BALANCES_ENDINGBALANCE_REVENUE')  # DSL_LINE:67
        print("EOD_REVENUE =", EOD_REVENUE)  # DSL_LINE:68
        ## Iteration
        revenue_adj = apply_each(recognition_results_LTD, "subtract(each,array_get(EOD_REVENUE,index,0))", {"recognition_results_LTD": recognition_results_LTD, "EOD_REVENUE": EOD_REVENUE})  # DSL_LINE:70
        print("revenue_adj =", revenue_adj)  # DSL_LINE:71

        REV = add(recognition_results, revenue_adj)  # DSL_LINE:73
        print("REV =", REV)  # DSL_LINE:74

        ## Create Transactions
        createTransaction(posting_date, posting_date, "REVENUE", REV, subinstrument_ids)  # DSL_LINE:77

        ## ═══════════════════════════════════════════════════════════════
        ## STAGE 3 - UNBILLED CHARGE
        ## ═══════════════════════════════════════════════════════════════

        ## Dependencies from saved rules
        ## Steps
        total_revenue = sum(recognition_results)  # DSL_LINE:85
        print("total_revenue =", total_revenue)  # DSL_LINE:86
        unbilled_charge = multiply(total_revenue, -1)  # DSL_LINE:87
        print("unbilled_charge =", unbilled_charge)  # DSL_LINE:88
        EOD_UNBILLED = EOD_BALANCES_ENDINGBALANCE_UNBILLED  # DSL_LINE:89
        print("EOD_UNBILLED =", EOD_UNBILLED)  # DSL_LINE:90
        EOD_BILLING = EOD_BALANCES_ENDINGBALANCE_BILLING  # DSL_LINE:91
        print("EOD_BILLING =", EOD_BILLING)  # DSL_LINE:92
        ## Conditional Logic
        Unbilled_amount = iif(gt(add(EOD_UNBILLED, unbilled_charge) , EOD_BILLING), unbilled_charge, multiply(EOD_UNBILLED, -1))  # DSL_LINE:94
        print("Unbilled_amount =", Unbilled_amount)  # DSL_LINE:95


        ## Create Transactions
        createTransaction(posting_date, posting_date, "UNBILLED_CHARGE", Unbilled_amount, 0.0)  # DSL_LINE:99
    
    # Get all transactions created via createTransaction()
    results = _get_transaction_results()
    return results

