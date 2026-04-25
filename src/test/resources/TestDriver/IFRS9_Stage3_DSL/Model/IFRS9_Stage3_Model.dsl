

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
        # Fields from ECF (activity)
        ECF_postingdate = str(get_field_case_insensitive(row, 'ECF_postingdate', ''))
        ECF_effectivedate = str(get_field_case_insensitive(row, 'ECF_effectivedate', ''))
        ECF_subinstrumentid = str(get_field_case_insensitive(row, 'ECF_subinstrumentid', '1'))
        ECF_StartDate = str(get_field_case_insensitive(row, 'ECF_StartDate', ''))
        ECF_ExpectedCF = float(get_field_case_insensitive(row, 'ECF_ExpectedCF', 0) or 0)
        ECF_MeasurementType = str(get_field_case_insensitive(row, 'ECF_MeasurementType', ''))
        # Fields from MeasurementType (reference)
        MeasurementType_MeasurementType = str(get_field_case_insensitive(row, 'MeasurementType_MeasurementType', ''))
        # Fields from EOD (activity)
        EOD_postingdate = str(get_field_case_insensitive(row, 'EOD_postingdate', ''))
        EOD_effectivedate = str(get_field_case_insensitive(row, 'EOD_effectivedate', ''))
        EOD_subinstrumentid = str(get_field_case_insensitive(row, 'EOD_subinstrumentid', '1'))
        EOD_ATTRIBUTE_LOANAMOUNT_CURRENT = float(get_field_case_insensitive(row, 'EOD_ATTRIBUTE_LOANAMOUNT_CURRENT', 0) or 0)
        EOD_ATTRIBUTE_TERM_CURRENT = float(get_field_case_insensitive(row, 'EOD_ATTRIBUTE_TERM_CURRENT', 0) or 0)
        EOD_ATTRIBUTE_NOTERATE_CURRENT = float(get_field_case_insensitive(row, 'EOD_ATTRIBUTE_NOTERATE_CURRENT', 0) or 0)
        EOD_ATTRIBUTE_ORIGINATIONDATE_CURRENT = str(get_field_case_insensitive(row, 'EOD_ATTRIBUTE_ORIGINATIONDATE_CURRENT', ''))
        EOD_BALANCES_BEGINNINGBALANCE_UPB = float(get_field_case_insensitive(row, 'EOD_BALANCES_BEGINNINGBALANCE_UPB', 0) or 0)
        EOD_BALANCES_ACTIVITY_UPB = float(get_field_case_insensitive(row, 'EOD_BALANCES_ACTIVITY_UPB', 0) or 0)
        EOD_BALANCES_ENDINGBALANCE_UPB = float(get_field_case_insensitive(row, 'EOD_BALANCES_ENDINGBALANCE_UPB', 0) or 0)
        EOD_BALANCES_ENDINGBALANCE_IMPAIRMENT = float(get_field_case_insensitive(row, 'EOD_BALANCES_ENDINGBALANCE_IMPAIRMENT', 0) or 0)
        EOD_BALANCES_BEGINNINGBALANCE_IMPAIRMENT = float(get_field_case_insensitive(row, 'EOD_BALANCES_BEGINNINGBALANCE_IMPAIRMENT', 0) or 0)
        EOD_BALANCES_ACTIVITY_IMPAIRMENT = float(get_field_case_insensitive(row, 'EOD_BALANCES_ACTIVITY_IMPAIRMENT', 0) or 0)
        
        # Execute DSL logic - transactions are created via createTransaction()
        ## ═══════════════════════════════════════════════════════════════
        ## STAGE 1 - PARAMETERS
        ## ═══════════════════════════════════════════════════════════════

        ## Dependencies from saved rules
        ## Steps
        MeasurementType = collect_all('MeasurementType_MeasurementType')  # DSL_LINE:7
        print("MeasurementType =", MeasurementType)  # DSL_LINE:8
        StartDate = collect_by_instrument('ECF_StartDate')  # DSL_LINE:9
        print("StartDate =", StartDate)  # DSL_LINE:10
        ExpectedCF = collect_by_instrument('ECF_ExpectedCF')  # DSL_LINE:11
        print("ExpectedCF =", ExpectedCF)  # DSL_LINE:12
        postingdate = EOD_postingdate  # DSL_LINE:13
        print("postingdate =", postingdate)  # DSL_LINE:14
        effectivedate = EOD_effectivedate  # DSL_LINE:15
        print("effectivedate =", effectivedate)  # DSL_LINE:16
        subinstrumentid = EOD_subinstrumentid  # DSL_LINE:17
        print("subinstrumentid =", subinstrumentid)  # DSL_LINE:18
        OriginationDate = EOD_ATTRIBUTE_ORIGINATIONDATE_CURRENT  # DSL_LINE:19
        print("OriginationDate =", OriginationDate)  # DSL_LINE:20
        LoanAmount = EOD_ATTRIBUTE_LOANAMOUNT_CURRENT  # DSL_LINE:21
        print("LoanAmount =", LoanAmount)  # DSL_LINE:22
        Term = EOD_ATTRIBUTE_TERM_CURRENT  # DSL_LINE:23
        print("Term =", Term)  # DSL_LINE:24
        NoteRate = EOD_ATTRIBUTE_NOTERATE_CURRENT  # DSL_LINE:25
        print("NoteRate =", NoteRate)  # DSL_LINE:26
        priotImpairment = EOD_BALANCES_ENDINGBALANCE_IMPAIRMENT  # DSL_LINE:27
        print("priotImpairment =", priotImpairment)  # DSL_LINE:28
        Monthly_Rate = NoteRate/1200  # DSL_LINE:29
        print("Monthly_Rate =", Monthly_Rate)  # DSL_LINE:30
        PMT_AM = pmt(Monthly_Rate,Term,-LoanAmount)  # DSL_LINE:31
        print("PMT_AM =", PMT_AM)  # DSL_LINE:32
        First_Month = months_between(OriginationDate,postingdate)  # DSL_LINE:33
        print("First_Month =", First_Month)  # DSL_LINE:34
        maturitydate = add_months(OriginationDate,Term)  # DSL_LINE:35
        print("maturitydate =", maturitydate)  # DSL_LINE:36
        ## Conditional Logic
        UPB = iif(eq(OriginationDate,postingdate), LoanAmount, EOD_BALANCES_ENDINGBALANCE_UPB)  # DSL_LINE:38
        print("UPB =", UPB)  # DSL_LINE:39


        ## ═══════════════════════════════════════════════════════════════
        ## STAGE 2 - SCHEDULE
        ## ═══════════════════════════════════════════════════════════════

        ## Dependencies from saved rules
        ## Steps
        ## Schedule
        p = period(postingdate, maturitydate, "M")  # DSL_LINE:49
        Schedule = schedule(p, {  # DSL_LINE:50
        "period_date": "period_date",  # DSL_LINE:51
        "month_end": "end_of_month(period_date)",  # DSL_LINE:52
        "monthNumber": "iif(eq(period_index,0),First_Month,lag('monthNumber',1,First_Month)+1)",  # DSL_LINE:53
        "openingBalance": "iif(eq(period_index,0),UPB,lag('closingBalance',1,0))",  # DSL_LINE:54
        "interestAccrued": "multiply(openingBalance,Monthly_Rate)",  # DSL_LINE:55
        "contractualCF": "iif(eq(month_end,maturitydate),add(interestAccrued,lag('closingBalance',1,0)),PMT_AM)",  # DSL_LINE:56
        "ExpectedCFA": "iif(eq(OriginationDate,postingdate),contractualCF,lookup(ExpectedCF, StartDate, month_end))",  # DSL_LINE:57
        "principalPayment": "contractualCF-interestAccrued",  # DSL_LINE:58
        "closingBalance": "subtract(openingBalance,principalPayment)",  # DSL_LINE:59
        "discountFactor": "1/pow(1+Monthly_Rate, monthNumber)",  # DSL_LINE:60
        "PV_CCF": "multiply(discountFactor,contractualCF)",  # DSL_LINE:61
        "PV_ECF": "multiply(discountFactor,ExpectedCFA)",  # DSL_LINE:62
        "impairmentCurrent": "subtract(PV_ECF,PV_CCF)",  # DSL_LINE:63
        "startdate": "StartDate"  # DSL_LINE:64
        }, {"First_Month": First_Month, "UPB": UPB, "Monthly_Rate": Monthly_Rate, "maturitydate": maturitydate, "PMT_AM": PMT_AM, "ExpectedCF": ExpectedCF, "StartDate": StartDate, "pow": pow, "OriginationDate": OriginationDate, "postingdate": postingdate})  # DSL_LINE:65
        print(Schedule)  # DSL_LINE:66
        interestAccrual = schedule_first(Schedule, "interestAccrued")  # DSL_LINE:67
        PeriodImpairment = schedule_sum(Schedule, "impairmentCurrent")  # DSL_LINE:68

        netImpairment = subtract(PeriodImpairment,priotImpairment)  # DSL_LINE:70
        print("netImpairment =", netImpairment)  # DSL_LINE:71
        Impairment_Gain = iif(gt(PeriodImpairment,0),PeriodImpairment,0)  # DSL_LINE:72
        print("Impairment_Gain =", Impairment_Gain)  # DSL_LINE:73
        Impairment_Loss = iif(lt(netImpairment,0),netImpairment,0)  # DSL_LINE:74
        print("Impairment_Loss =", Impairment_Loss)  # DSL_LINE:75
        Interest_Accrual = iif(eq(OriginationDate,postingdate),0,interestAccrual)  # DSL_LINE:76
        print("Interest_Accrual =", Interest_Accrual)  # DSL_LINE:77
        Origination_Principal = iif(eq(OriginationDate,postingdate),LoanAmount,0)  # DSL_LINE:78
        print("Origination_Principal =", Origination_Principal)  # DSL_LINE:79

        ## Create Transactions
        createTransaction(postingdate, effectivedate, "IMPAIRMENT_GAIN", Impairment_Gain, subinstrumentid)  # DSL_LINE:82
        createTransaction(postingdate, postingdate, "IMPAIRMENT_LOSS", Impairment_Loss, subinstrumentid)  # DSL_LINE:83
        createTransaction(postingdate, postingdate, "INTEREST_ACCRUAL", Interest_Accrual, subinstrumentid)  # DSL_LINE:84
        createTransaction(postingdate, postingdate, "ORIGINATION_PRINCIPAL", Origination_Principal, subinstrumentid)  # DSL_LINE:85
    
    # Get all transactions created via createTransaction()
    results = _get_transaction_results()
    return results

