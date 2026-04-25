

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
        # Fields from TRANX (activity)
        TRANX_postingdate = str(get_field_case_insensitive(row, 'TRANX_postingdate', ''))
        TRANX_effectivedate = str(get_field_case_insensitive(row, 'TRANX_effectivedate', ''))
        TRANX_subinstrumentid = str(get_field_case_insensitive(row, 'TRANX_subinstrumentid', '1'))
        TRANX_TRANSACTIONS_AMOUNT_REMIT = float(get_field_case_insensitive(row, 'TRANX_TRANSACTIONS_AMOUNT_REMIT', 0) or 0)
        # Fields from REPLAY (activity)
        REPLAY_postingdate = str(get_field_case_insensitive(row, 'REPLAY_postingdate', ''))
        REPLAY_effectivedate = str(get_field_case_insensitive(row, 'REPLAY_effectivedate', ''))
        REPLAY_subinstrumentid = str(get_field_case_insensitive(row, 'REPLAY_subinstrumentid', '1'))
        REPLAY_TRANSACTIONS_AMOUNT_REMIT = float(get_field_case_insensitive(row, 'REPLAY_TRANSACTIONS_AMOUNT_REMIT', 0) or 0)
        REPLAY_TRANSACTIONS_AMOUNT_PAYMENT_UPB = float(get_field_case_insensitive(row, 'REPLAY_TRANSACTIONS_AMOUNT_PAYMENT_UPB', 0) or 0)
        REPLAY_ATTRIBUTE_MERCHANT_INDUSTRY_CURRENT = str(get_field_case_insensitive(row, 'REPLAY_ATTRIBUTE_MERCHANT_INDUSTRY_CURRENT', ''))
        REPLAY_TRANSACTIONS_AMOUNT_SERVICING_INTEREST_ACCRUAL = float(get_field_case_insensitive(row, 'REPLAY_TRANSACTIONS_AMOUNT_SERVICING_INTEREST_ACCRUAL', 0) or 0)
        # Fields from EOD (activity)
        EOD_postingdate = str(get_field_case_insensitive(row, 'EOD_postingdate', ''))
        EOD_effectivedate = str(get_field_case_insensitive(row, 'EOD_effectivedate', ''))
        EOD_subinstrumentid = str(get_field_case_insensitive(row, 'EOD_subinstrumentid', '1'))
        EOD_BALANCES_ENDINGBALANCE_ACCRUED_INTEREST_RECEIVABLE = float(get_field_case_insensitive(row, 'EOD_BALANCES_ENDINGBALANCE_ACCRUED_INTEREST_RECEIVABLE', 0) or 0)
        EOD_BALANCES_BEGINNINGBALANCE_ACCRUED_INTEREST_RECEIVABLE = float(get_field_case_insensitive(row, 'EOD_BALANCES_BEGINNINGBALANCE_ACCRUED_INTEREST_RECEIVABLE', 0) or 0)
        EOD_BALANCES_ENDINGBALANCE_SERVICING_INTEREST_ACCRUAL = float(get_field_case_insensitive(row, 'EOD_BALANCES_ENDINGBALANCE_SERVICING_INTEREST_ACCRUAL', 0) or 0)
        EOD_BALANCES_ENDINGBALANCE_UNPAID_PRINCIPAL_BALANCE = float(get_field_case_insensitive(row, 'EOD_BALANCES_ENDINGBALANCE_UNPAID_PRINCIPAL_BALANCE', 0) or 0)
        EOD_BALANCES_BEGINNINGBALANCE_UNPAID_PRINCIPAL_BALANCE = float(get_field_case_insensitive(row, 'EOD_BALANCES_BEGINNINGBALANCE_UNPAID_PRINCIPAL_BALANCE', 0) or 0)
        EOD_BALANCES_ACTIVITY_UNPAID_PRINCIPAL_BALANCE = float(get_field_case_insensitive(row, 'EOD_BALANCES_ACTIVITY_UNPAID_PRINCIPAL_BALANCE', 0) or 0)
        EOD_BALANCES_ACTIVITY_SERVICING_INTEREST_ACCRUAL = float(get_field_case_insensitive(row, 'EOD_BALANCES_ACTIVITY_SERVICING_INTEREST_ACCRUAL', 0) or 0)
        EOD_BALANCES_BEGINNINGBALANCE_SERVICING_INTEREST_ACCRUAL = float(get_field_case_insensitive(row, 'EOD_BALANCES_BEGINNINGBALANCE_SERVICING_INTEREST_ACCRUAL', 0) or 0)
        EOD_BALANCES_ACTIVITY_ACCRUED_INTEREST_RECEIVABLE = float(get_field_case_insensitive(row, 'EOD_BALANCES_ACTIVITY_ACCRUED_INTEREST_RECEIVABLE', 0) or 0)
        EOD_ATTRIBUTE_INTEREST_RATE_CURRENT = float(get_field_case_insensitive(row, 'EOD_ATTRIBUTE_INTEREST_RATE_CURRENT', 0) or 0)
        
        # Execute DSL logic - transactions are created via createTransaction()
        ## ═══════════════════════════════════════════════════════════════
        ## STEP 1 - PARAMETERS
        ## ═══════════════════════════════════════════════════════════════

        ## Steps
        replay_remit = collect_by_instrument('REPLAY_TRANSACTIONS_AMOUNT_REMIT')  # DSL_LINE:6
        print("replay_remit =", replay_remit)  # DSL_LINE:7
        posting_date = EOD_postingdate  # DSL_LINE:8
        print("posting_date =", posting_date)  # DSL_LINE:9
        Current_Acc_Bal = EOD_BALANCES_BEGINNINGBALANCE_SERVICING_INTEREST_ACCRUAL  # DSL_LINE:10
        print("Current_Acc_Bal =", Current_Acc_Bal)  # DSL_LINE:11
        Current_UPB_Bal = EOD_BALANCES_BEGINNINGBALANCE_UNPAID_PRINCIPAL_BALANCE  # DSL_LINE:12
        print("Current_UPB_Bal =", Current_UPB_Bal)  # DSL_LINE:13
        replay_date = REPLAY_effectivedate  # DSL_LINE:14
        print("replay_date =", replay_date)  # DSL_LINE:15
        payment_date = TRANX_effectivedate  # DSL_LINE:16
        print("payment_date =", payment_date)  # DSL_LINE:17
        payment_amount = iif(eq(payment_date,posting_date),TRANX_TRANSACTIONS_AMOUNT_REMIT,0)  # DSL_LINE:18
        print("payment_amount =", payment_amount)  # DSL_LINE:19
        effective_date = EOD_effectivedate  # DSL_LINE:20
        print("effective_date =", effective_date)  # DSL_LINE:21
        subinstrumentid = EOD_subinstrumentid  # DSL_LINE:22
        print("subinstrumentid =", subinstrumentid)  # DSL_LINE:23
        interest_rate = EOD_ATTRIBUTE_INTEREST_RATE_CURRENT/100  # DSL_LINE:24
        print("interest_rate =", interest_rate)  # DSL_LINE:25
        timeline_list = array_append(collect_by_instrument('REPLAY_effectivedate'),posting_date)  # DSL_LINE:26
        print("timeline_list =", timeline_list)  # DSL_LINE:27
        REPLAY_REP_RAYMENTUPB_arr = collect_by_instrument('REPLAY_TRANSACTIONS_AMOUNT_PAYMENT_UPB')  # DSL_LINE:28
        print("REPLAY_REP_RAYMENTUPB_arr =", REPLAY_REP_RAYMENTUPB_arr)  # DSL_LINE:29
        REPLAY_REP_SIA_arr = collect_by_instrument('REPLAY_TRANSACTIONS_AMOUNT_SERVICING_INTEREST_ACCRUAL')  # DSL_LINE:30
        print("REPLAY_REP_SIA_arr =", REPLAY_REP_SIA_arr)  # DSL_LINE:31

        ## ═══════════════════════════════════════════════════════════════
        ## STEP 2 - SCHEDULE
        ## ═══════════════════════════════════════════════════════════════

        ## Dependencies from saved rules
        ## Steps
        timelinelist_count = count(timeline_list)  # DSL_LINE:39
        print("timelinelist_count =", timelinelist_count)  # DSL_LINE:40
        ## Schedule
        p = period(timelinelist_count, "M")  # DSL_LINE:42
        BACKTRACK_SCHEDULE = schedule(p, {  # DSL_LINE:43
        "date": "timeline_list",  # DSL_LINE:44
        "Accrual_Days": "days_between(lag('date',1,0),date)",  # DSL_LINE:45
        "Accrual_Amount": "REPLAY_REP_SIA_arr",  # DSL_LINE:46
        "days_accrual": "multiply(Accrual_Days,lag('Accrual_Amount',1,0))"  # DSL_LINE:47
        }, {"timeline_list": timeline_list, "REPLAY_REP_SIA_arr": REPLAY_REP_SIA_arr})  # DSL_LINE:48
        print(BACKTRACK_SCHEDULE)  # DSL_LINE:49
        days_accrual = schedule_sum(BACKTRACK_SCHEDULE, "days_accrual")  # DSL_LINE:50

        replay_air = subtract(Current_Acc_Bal,days_accrual)  # DSL_LINE:52
        print("replay_air =", replay_air)  # DSL_LINE:53
        replay_upb = subtract(Current_UPB_Bal,sum(REPLAY_REP_RAYMENTUPB_arr))  # DSL_LINE:54
        print("replay_upb =", replay_upb)  # DSL_LINE:55
        ## Schedule
        p = period(timelinelist_count, "M")  # DSL_LINE:57
        Schedule = schedule(p, {  # DSL_LINE:58
        "date": "timeline_list",  # DSL_LINE:59
        "days": "iif(eq(period_index, 0),0,days_between(lag('date',1,0),date)-1)",  # DSL_LINE:60
        "Beg_UPB": "iif(eq(period_index, 0), replay_upb, lag('End_UPB',1,0))",  # DSL_LINE:61
        "Beg_AIR": "iif(eq(period_index, 0),replay_air,lag('End_AIR',1,0)+(lag('Accrual',1,0)*days))",  # DSL_LINE:62
        "Remit_am": "coalesce(replay_remit,0)",  # DSL_LINE:63
        "Int_Paid": "min(Remit_am,Beg_AIR)",  # DSL_LINE:64
        "Prin_Paid": "max(Remit_am-Int_Paid,0)",  # DSL_LINE:65
        "End_UPB": "subtract(Beg_UPB,Prin_Paid)",  # DSL_LINE:66
        "Accrual": "(interest_rate*End_UPB)/360",  # DSL_LINE:67
        "End_AIR": "Beg_AIR-Int_Paid+Accrual"  # DSL_LINE:68
        }, {"timeline_list": timeline_list, "replay_upb": replay_upb, "replay_air": replay_air, "replay_remit": replay_remit, "interest_rate": interest_rate})  # DSL_LINE:69
        print(Schedule)  # DSL_LINE:70
        Replay_EndingUPB = schedule_last(Schedule, "End_UPB")  # DSL_LINE:71
        Replay_EndingAIR = schedule_last(Schedule, "End_AIR")  # DSL_LINE:72


        ## ═══════════════════════════════════════════════════════════════
        ## STEP 3 - ACCRUAL
        ## ═══════════════════════════════════════════════════════════════

        ## Dependencies from saved rules
        ## Steps
        BeginningUPB = EOD_BALANCES_BEGINNINGBALANCE_UNPAID_PRINCIPAL_BALANCE  # DSL_LINE:81
        print("BeginningUPB =", BeginningUPB)  # DSL_LINE:82
        BeginningAIR = EOD_BALANCES_BEGINNINGBALANCE_ACCRUED_INTEREST_RECEIVABLE  # DSL_LINE:83
        print("BeginningAIR =", BeginningAIR)  # DSL_LINE:84
        Payment_interest = min(payment_amount, BeginningAIR)*-1  # DSL_LINE:85
        print("Payment_interest =", Payment_interest)  # DSL_LINE:86
        payment_principal = max(payment_amount+Payment_interest, 0)*-1  # DSL_LINE:87
        print("payment_principal =", payment_principal)  # DSL_LINE:88
        InterestAccrual = ((BeginningUPB+payment_principal)*interest_rate)/360  # DSL_LINE:89
        print("InterestAccrual =", InterestAccrual)  # DSL_LINE:90
        EndingUPB = BeginningUPB+payment_principal  # DSL_LINE:91
        print("EndingUPB =", EndingUPB)  # DSL_LINE:92
        EndingAIR = BeginningAIR+Payment_interest+InterestAccrual  # DSL_LINE:93
        print("EndingAIR =", EndingAIR)  # DSL_LINE:94
        ## Conditional Logic
        Principal_Adj = iif(eq(Replay_EndingUPB,0), 0, subtract(Replay_EndingUPB,EndingUPB))  # DSL_LINE:96
        print("Principal_Adj =", Principal_Adj)  # DSL_LINE:97

        ## Conditional Logic
        Interest_Adj = iif(eq(Replay_EndingAIR,0), 0, subtract(Replay_EndingAIR,EndingAIR))  # DSL_LINE:100
        print("Interest_Adj =", Interest_Adj)  # DSL_LINE:101


        ## Create Transactions
        createTransaction(posting_date, posting_date, "Principal_Adjustment", Principal_Adj, subinstrumentid)  # DSL_LINE:105
        createTransaction(posting_date, posting_date, "Interest_Adjustment", Interest_Adj, subinstrumentid)  # DSL_LINE:106
        createTransaction(posting_date, payment_date, "Payment_UPB", payment_principal, subinstrumentid)  # DSL_LINE:107
        createTransaction(posting_date, payment_date, "Payment_Interest", Payment_interest, subinstrumentid)  # DSL_LINE:108
        createTransaction(posting_date, posting_date, "Servicing_Interest_Accrual", InterestAccrual, subinstrumentid)  # DSL_LINE:109
    
    # Get all transactions created via createTransaction()
    results = _get_transaction_results()
    return results
