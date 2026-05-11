

import sys, os
# Ensure backend package folder is on path so imports work when executed from different cwd
ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__)))
if ROOT_DIR not in sys.path:
    sys.path.insert(0, ROOT_DIR)
try:
    from backend.dsl_functions import DSL_FUNCTIONS, _set_current_instrumentid, _clear_transaction_results, _get_transaction_results, _set_dsl_print
except Exception:
    from dsl_functions import DSL_FUNCTIONS, _set_current_instrumentid, _clear_transaction_results, _get_transaction_results, _set_dsl_print
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

# Restore Python built-ins (needed for native Python syntax)
min = _builtin_min
max = _builtin_max
sum = _builtin_sum
len = _builtin_len
range = _builtin_range

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
                except:
                    output_parts.append(str(arg))
            else:
                output_parts.append(str(arg))

        sep = kwargs.get('sep', ' ')
        output = sep.join(output_parts)
        _print_outputs.append(output)
        # Also print to stdout for debugging
        _builtin_print(output)
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
    _raw_event_data = data

def set_current_context(instrumentid, postingdate, effectivedate, subinstrumentid='1'):
    """Set the current row context for filtering collect()"""
    global _current_context
    _current_context = {
        'instrumentid': instrumentid,
        'subinstrumentid': subinstrumentid or '1',
        'postingdate': postingdate,
        'effectivedate': effectivedate
    }

def collect(field_name):
    """
    Collect all values of a field for the current instrumentid, postingdate, and effectivedate.
    Usage: cashflows = collect('ECF_ExpectedCF')
    Returns a list of numeric values from RAW event data (all rows, not merged).
    """
    values = []
    current_instrument = _current_context.get('instrumentid', '')
    current_posting = _current_context.get('postingdate', '')
    current_effective = _current_context.get('effectivedate', '')
    
    # Parse field_name to get event name and field (e.g., 'ECF_ExpectedCF' -> 'ECF', 'ExpectedCF')
    parts = field_name.split('_', 1)
    if len(parts) == 2:
        event_name, actual_field = parts[0], parts[1]
    else:
        event_name, actual_field = None, field_name
    
    # Search in raw event data
    for evt_name, rows in _raw_event_data.items():
        # If event_name specified, only search that event
        if event_name and evt_name.upper() != event_name.upper():
            continue
            
        for row in rows:
            row_instrument = get_field_case_insensitive(row, 'instrumentid', '')
            row_posting = get_field_case_insensitive(row, 'postingdate', '')
            row_effective = get_field_case_insensitive(row, 'effectivedate', '') or row_posting
            
            if (row_instrument == current_instrument and 
                row_posting == current_posting and 
                row_effective == current_effective):
                # Try the actual field name
                val = get_field_case_insensitive(row, actual_field, None)
                if val is None:
                    # Try the full field name
                    val = get_field_case_insensitive(row, field_name, None)
                if val is not None and val != '':
                    try:
                        values.append(float(val))
                    except (ValueError, TypeError):
                        # Keep string values (dates, etc.)
                        values.append(str(val))
    return values

def collect_by_instrument(field_name):
    """
    Collect all values of a field for the current instrumentid only (ignores dates).
    Useful for time-series data across multiple periods for same instrument.
    Returns numeric values as floats, non-numeric (dates, strings) as strings.
    """
    values = []
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
                if val is not None and val != '':
                    try:
                        values.append(float(val))
                    except (ValueError, TypeError):
                        # Keep string values (dates, etc.)
                        values.append(str(val))
    return values

def collect_all(field_name):
    """
    Collect ALL values of a field across all data rows (no filtering).
    Returns numeric values as floats, non-numeric (dates, strings) as strings.
    """
    values = []
    
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
            val = get_field_case_insensitive(row, actual_field, None)
            if val is None:
                val = get_field_case_insensitive(row, field_name, None)
            if val is not None and val != '':
                try:
                    values.append(float(val))
                except (ValueError, TypeError):
                    # Keep string values (dates, etc.)
                    values.append(str(val))
    return values

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
    
    for row in event_data:
        # Extract standard fields (case-insensitive)
        postingdate = get_field_case_insensitive(row, 'postingdate', '')
        effectivedate = get_field_case_insensitive(row, 'effectivedate', '') or postingdate
        instrumentid = get_field_case_insensitive(row, 'instrumentid', '')
        subinstrumentid = get_field_case_insensitive(row, 'subinstrumentid', '1') or '1'
        
        # Set current instrumentid for createTransaction()
        _set_current_instrumentid(instrumentid)
        
        # Set current context for collect() filtering
        set_current_context(instrumentid, postingdate, effectivedate, subinstrumentid)
        
        # Extract fields from all events with proper datatype conversion
        # Fields from DEFAULT (activity)
        DEFAULT_postingdate = str(get_field_case_insensitive(row, 'DEFAULT_postingdate', ''))
        DEFAULT_effectivedate = str(get_field_case_insensitive(row, 'DEFAULT_effectivedate', ''))
        DEFAULT_subinstrumentid = str(get_field_case_insensitive(row, 'DEFAULT_subinstrumentid', '1'))
        DEFAULT_TRANSACTIONS_AMOUNT_REMIT = float(get_field_case_insensitive(row, 'DEFAULT_TRANSACTIONS_AMOUNT_REMIT', 0) or 0)
        
        # Execute DSL logic - transactions are created via createTransaction()
        ## ═══════════════════════════════════════════
        ## Imported Event Fields
        ## ═══════════════════════════════════════════

        ## INT_ACC Fields
        INT_ACC_postingdate = INT_ACC_postingdate
        INT_ACC_effectivedate = INT_ACC_effectivedate
        INT_ACC_subinstrumentid = INT_ACC_subinstrumentid
        print(INT_ACC_subinstrumentid)
        int_rate_current = INT_ACC_ATTRIBUTE_INTEREST_RATE_CURRENT
        unpaid_principal_balance = INT_ACC_BALANCES_ENDINGBALANCE_Unpaid_Principal_Balance
        accrued_interest_receivable = INT_ACC_BALANCES_ENDINGBALANCE_Accrued_Interest_Receivable
        servicing_interest_accrual = INT_ACC_BALANCES_ENDINGBALANCE_Servicing_Interest_Accrual

        ## PMT Fields
        PMT_postingdate = PMT_postingdate
        PMT_effectivedate = PMT_effectivedate
        pmt_remit = PMT_TRANSACTIONS_AMOUNT_REMIT

        ## ORIG Fields
        ORIG_postingdate = ORIG_postingdate
        ORIG_effectivedate = ORIG_effectivedate
        Purchase_upb = ORIG_ATTRIBUTE_LOAN_AMOUNT_CURRENT
        Purchase_air = ORIG_ATTRIBUTE_INTEREST_RECEIVABLE_CONSUMER_CURRENT

        ## ═══════════════════════════════════════════
        ## SBO
        ## ═══════════════════════════════════════════


        Payment_interest = min(pmt_remit, accrued_interest_receivable)*-1
        payment_principal = max(pmt_remit+Payment_interest, 0)*-1

        InterestAccrual = ((unpaid_principal_balance+payment_principal)*int_rate_current)/36000

        ## ═══════════════════════════════════════════
        ## Transaction Outputs
        ## ═══════════════════════════════════════════


        createTransaction(ORIG_postingdate , ORIG_effectivedate, "Purchase_Principal", Purchase_upb,"1.0")

        createTransaction(ORIG_postingdate , ORIG_effectivedate, "Purchase_Interest", Purchase_air,"1.0")

        createTransaction(PMT_postingdate, PMT_effectivedate, "Payment_Interest", Payment_interest,"1.0")

        createTransaction(PMT_postingdate, PMT_effectivedate, "Payment_Principal", payment_principal,"1.0")

        createTransaction(INT_ACC_postingdate , INT_ACC_effectivedate, "Interest_Accrual", InterestAccrual,"1.0")
    
    # Get all transactions created via createTransaction()
    results = _get_transaction_results()
    return results
