%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.alloc import alloc
from starkware.starknet.common.syscalls import (
    get_caller_address,
    get_contract_address,
    get_block_timestamp,
)
from starkware.cairo.common.math import assert_nn, assert_le, assert_not_zero
from starkware.cairo.common.math_cmp import is_not_zero
from starkware.cairo.common.uint256 import (
    Uint256,
    uint256_add,
    uint256_sub,
    uint256_mul,
    uint256_unsigned_div_rem,
    uint256_le,
    uint256_lt,
    uint256_check,
    uint256_eq,
)

from openzeppelin.token.erc20.interfaces.IERC20 import IERC20
from contracts.settling_game.interfaces.IERC1155 import IERC1155
from openzeppelin.token.erc1155.library import (
    ERC1155_initializer,
    ERC1155_supportsInterface,
    ERC1155_uri,
    ERC1155_balanceOf,
    ERC1155_balanceOfBatch,
    ERC1155_isApprovedForAll,
    ERC1155_setApprovalForAll,
    ERC1155_safeTransferFrom,
    ERC1155_safeBatchTransferFrom,
    ERC1155_mint,
    ERC1155_burn,
    owner_or_approved,
    IERC1155_RECEIVER_ID,
    ON_ERC1155_RECEIVED_SELECTOR,
)

@event
func liquidity_added(
    caller : felt, currency_amount : Uint256, token_id : Uint256, token_amount : Uint256
):
end

@event
func liquidity_removed(
    caller : felt, currency_amount : Uint256, token_id : Uint256, token_amount : Uint256
):
end

@event
func tokens_purchased(
    caller : felt, currency_sold : Uint256, token_id : Uint256, tokens_bought : Uint256
):
end

@event
func currency_purchased(
    caller : felt, currency_bought : Uint256, token_id : Uint256, tokens_sold : Uint256
):
end

# Contract Address of ERC20 address for this swap contract
@storage_var
func currency_address() -> (address : felt):
end

# Contract Address of ERC1155 address for this swap contract
@storage_var
func token_address() -> (address : felt):
end

# Current reserves of currency
@storage_var
func currency_reserves(token_id : Uint256) -> (reserves : Uint256):
end

# Total issued LP totals
@storage_var
func lp_reserves(token_id : Uint256) -> (total : Uint256):
end

# Liquidity pool rewards in thousandths (e.g. 15 = 1.5% fee)
@storage_var
func lp_fee_thousands() -> (lp_fee_thousands : Uint256):
end

# Note: We use ERC1155_balanceOf(contract_address) to record token reserves

# Global royalty fee in thousandths (e.g. 15 = 1.5% fee)
@storage_var
func royalty_fee_thousands() -> (royalty_fee_thousands : Uint256):
end

# Global royalty fee addr
@storage_var
func royalty_fee_address() -> (royalty_fee_address : felt):
end

@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    currency_address_ : felt,
    token_address_ : felt,
    lp_fee_thousands_ : Uint256,
    royalty_fee_thousands_ : Uint256,
    royalty_fee_address_ : felt,
):
    currency_address.write(currency_address_)
    token_address.write(token_address_)
    lp_fee_thousands.write(lp_fee_thousands_)
    set_royalty_info(royalty_fee_thousands_, royalty_fee_address_)
    return ()
end

#
# Admin
#

@external
func set_royalty_info{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    royalty_fee_thousands_ : Uint256, royalty_fee_address_ : felt
):
    royalty_fee_thousands.write(royalty_fee_thousands_)
    royalty_fee_address.write(royalty_fee_address_)
    return ()
end

#
# Liquidity
#

# input arguments are 3 arrays of:
# 1) amount of currency supplied to LP
# 2) ERC1155 token IDs
# 3) amount of tokens supplied
@external
func initial_liquidity{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    currency_amounts_len : felt,
    currency_amounts : Uint256*,
    token_ids_len : felt,
    token_ids : Uint256*,
    token_amounts_len : felt,
    token_amounts : Uint256*,
):
    alloc_locals

    # Recursive break
    if currency_amounts_len == 0:
        return ()
    end

    assert currency_amounts_len = token_ids_len
    assert currency_amounts_len = token_amounts_len

    let (caller) = get_caller_address()
    let (contract) = get_contract_address()

    let (token_address_) = token_address.read()
    let (currency_address_) = currency_address.read()

    # Only valid for first liquidity add to LP
    let (currency_reserves_ : Uint256) = currency_reserves.read([token_ids])
    with_attr error_message("Only valid for initial liquidity add"):
        assert currency_reserves_ = Uint256(0, 0)
    end

    # Transfer currency and token to exchange
    IERC20.transferFrom(currency_address_, caller, contract, [currency_amounts])
    tempvar syscall_ptr : felt* = syscall_ptr
    IERC1155.safeTransferFrom(token_address_, caller, contract, [token_ids], [token_amounts])

    # Assert otherwise rounding error could end up being significant on second deposit
    let (ok) = uint256_le(Uint256(1000, 0), [currency_amounts])
    with_attr error_message("Must supply larger currency for initial deposit"):
        assert_not_zero(ok)
    end

    # Update currency reserve size for token id before transfer
    currency_reserves.write([token_ids], [currency_amounts])

    # Initial liquidity is currency amount deposited
    lp_reserves.write([token_ids], [currency_amounts])

    # Mint LP tokens
    ERC1155_mint(caller, [token_ids], [currency_amounts])

    # Emit event
    liquidity_added.emit(caller, [currency_amounts], [token_ids], [token_amounts])

    # Recurse
    return initial_liquidity(
        currency_amounts_len - 1,
        currency_amounts + Uint256.SIZE,
        token_ids_len - 1,
        token_ids + Uint256.SIZE,
        token_amounts_len - 1,
        token_amounts + Uint256.SIZE,
    )
end

# input arguments are:
# 1) array of maximum amount of currency supplied to LP
# 2) array of ERC1155 token IDs
# 3) array of fixed amount of tokens supplied
# 4) the maximum time which this transaction can be accepted
@external
func add_liquidity{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    max_currency_amounts_len : felt,
    max_currency_amounts : Uint256*,
    token_ids_len : felt,
    token_ids : Uint256*,
    token_amounts_len : felt,
    token_amounts : Uint256*,
    deadline : felt,
):
    alloc_locals

    assert max_currency_amounts_len = token_ids_len
    assert max_currency_amounts_len = token_amounts_len

    # Check deadline within bounds
    let (block_timestamp) = get_block_timestamp()
    with_attr error_message("Deadline exceeded"):
        assert_le(block_timestamp, deadline)
    end

    return add_liquidity_loop(
        max_currency_amounts_len,
        max_currency_amounts,
        token_ids_len,
        token_ids,
        token_amounts_len,
        token_amounts,
    )
end

# input arguments are:
# 1) array of maximum amount of currency supplied to LP
# 2) array of ERC1155 token IDs
# 3) array of fixed amount of token supplied
func add_liquidity_loop{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    max_currency_amounts_len : felt,
    max_currency_amounts : Uint256*,
    token_ids_len : felt,
    token_ids : Uint256*,
    token_amounts_len : felt,
    token_amounts : Uint256*,
):
    alloc_locals

    # Recursive break
    if max_currency_amounts_len == 0:
        return ()
    end

    let (caller) = get_caller_address()
    let (contract) = get_contract_address()

    let (token_address_) = token_address.read()
    let (currency_address_) = currency_address.read()

    # Read current reserve levels
    let (lp_reserves_ : Uint256) = lp_reserves.read([token_ids])
    let (token_reserves : Uint256) = IERC1155.balanceOf(token_address_, contract, [token_ids])
    let (currency_reserves_ : Uint256) = currency_reserves.read([token_ids])

    # Ensure this method is only called for subsequent liquidity adds
    let (above_zero) = uint256_lt(Uint256(0, 0), currency_reserves_)
    with_attr error_message("This method is only for subsequent liquidity additions"):
        assert_not_zero(above_zero)
    end

    # Required price calc
    # X/Y = dx/dy
    # dx = X*dy/Y
    let (numerator, mul_overflow) = uint256_mul(currency_reserves_, [token_amounts])
    with_attr error_message("Values too large"):
        assert mul_overflow = Uint256(0, 0)
    end
    let (currency_amount, _) = uint256_unsigned_div_rem(numerator, token_reserves)
    # Ignore remainder as this favours existing LP holders

    # Check within bounds of the maximum allowed currency spend
    let (ok) = uint256_le(currency_amount, [max_currency_amounts])
    with_attr error_message("Price exceeds max currency amount"):
        assert_not_zero(ok)
    end

    # Transfer tokens to exchange contract
    IERC20.transferFrom(currency_address_, caller, contract, currency_amount)
    tempvar syscall_ptr : felt* = syscall_ptr
    IERC1155.safeTransferFrom(token_address_, caller, contract, [token_ids], [token_amounts])

    # Update the new currency and LP reserves
    let (new_reserves, add_overflow) = uint256_add(currency_reserves_, currency_amount)
    with_attr error_message("Currency value overflow"):
        assert (add_overflow) = 0
    end
    currency_reserves.write([token_ids], new_reserves)
    let (new_supplies, add_overflow) = uint256_add(lp_reserves_, currency_amount)
    with_attr error_message("LP value overflow"):
        assert (add_overflow) = 0
    end
    lp_reserves.write([token_ids], new_supplies)

    # Mint LP tokens
    ERC1155_mint(caller, [token_ids], currency_amount)

    # Emit event
    liquidity_added.emit(caller, currency_amount, [token_ids], [token_amounts])

    return add_liquidity_loop(
        max_currency_amounts_len - 1,
        max_currency_amounts + Uint256.SIZE,
        token_ids_len - 1,
        token_ids + Uint256.SIZE,
        token_amounts_len - 1,
        token_amounts + Uint256.SIZE,
    )
end

# input arguments are
# 1) array of minimum amount of currency received from LP
# 2) array of ERC1155 token IDs
# 3) array of minimum amount of tokens received from LP
# 4) array of exact amount of LP tokens to spend
# 5) maximum time which this transaction can be accepted
@external
func remove_liquidity{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    min_currency_amounts_len : felt,
    min_currency_amounts : Uint256*,
    token_ids_len : felt,
    token_ids : Uint256*,
    min_token_amounts_len : felt,
    min_token_amounts : Uint256*,
    lp_amounts_len : felt,
    lp_amounts : Uint256*,
    deadline : felt,
):
    alloc_locals

    assert min_currency_amounts_len = token_ids_len
    assert min_currency_amounts_len = min_token_amounts_len
    assert min_currency_amounts_len = lp_amounts_len

    # Check deadline within bounds
    let (block_timestamp) = get_block_timestamp()
    with_attr error_message("Deadline exceeded"):
        assert_le(block_timestamp, deadline)
    end

    return remove_liquidity_loop(
        min_currency_amounts_len,
        min_currency_amounts,
        token_ids_len,
        token_ids,
        min_token_amounts_len,
        min_token_amounts,
        lp_amounts_len,
        lp_amounts,
    )
end

func remove_liquidity_loop{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    min_currency_amounts_len : felt,
    min_currency_amounts : Uint256*,
    token_ids_len : felt,
    token_ids : Uint256*,
    min_token_amounts_len : felt,
    min_token_amounts : Uint256*,
    lp_amounts_len : felt,
    lp_amounts : Uint256*,
):
    alloc_locals

    # Recursive break
    if min_currency_amounts_len == 0:
        return ()
    end

    let (caller) = get_caller_address()
    let (contract) = get_contract_address()

    let (token_address_) = token_address.read()
    let (currency_address_) = currency_address.read()

    # Read current reserve levels
    let (lp_reserves_ : Uint256) = lp_reserves.read([token_ids])
    let (currency_reserves_ : Uint256) = currency_reserves.read([token_ids])
    let (token_reserves : Uint256) = IERC1155.balanceOf(token_address_, contract, [token_ids])

    let (new_supplies) = uint256_sub(lp_reserves_, [lp_amounts])
    # It should not be possible to go below zero as LP reflects supply
    let (above_zero) = uint256_le(Uint256(0, 0), new_supplies)
    with_attr error_message("LP total exceeded"):
        assert_not_zero(above_zero)
    end

    # Calculate percentage of reserves this LP amount is worth
    let (numerator, mul_overflow) = uint256_mul(currency_reserves_, [lp_amounts])
    with_attr error_message("Values too large"):
        assert mul_overflow = Uint256(0, 0)
    end
    let (currency_owed, _) = uint256_unsigned_div_rem(numerator, lp_reserves_)
    let (numerator, mul_overflow) = uint256_mul(token_reserves, [lp_amounts])
    with_attr error_message("Values too large"):
        assert mul_overflow = Uint256(0, 0)
    end
    # Ignore remainder as it favours LP holders
    let (tokens_owed, _) = uint256_unsigned_div_rem(numerator, lp_reserves_)

    # Check actual values to receive are above minimum values requested
    let (above_min) = uint256_le([min_currency_amounts], currency_owed)
    with_attr error_message("Minimum currency amount exceeded"):
        assert_not_zero(above_min)
    end
    let (above_min) = uint256_le([min_token_amounts], tokens_owed)
    with_attr error_message("Minimum token amount exceeded"):
        assert_not_zero(above_min)
    end

    # New totals
    let (new_currency) = uint256_sub(currency_reserves_, currency_owed)

    # Update storage
    lp_reserves.write([token_ids], new_supplies)
    currency_reserves.write([token_ids], new_currency)

    # Take LP tokens
    ERC1155_burn(caller, [token_ids], [lp_amounts])
    # Send currency and tokens
    IERC20.transfer(currency_address_, caller, currency_owed)
    tempvar syscall_ptr : felt* = syscall_ptr
    IERC1155.safeTransferFrom(token_address_, contract, caller, [token_ids], tokens_owed)

    # Emit event
    liquidity_removed.emit(caller, currency_owed, [token_ids], tokens_owed)

    return remove_liquidity_loop(
        min_currency_amounts_len - 1,
        min_currency_amounts + Uint256.SIZE,
        token_ids_len - 1,
        token_ids + Uint256.SIZE,
        min_token_amounts_len - 1,
        min_token_amounts + Uint256.SIZE,
        lp_amounts_len - 1,
        lp_amounts + Uint256.SIZE,
    )
end

#
# Swaps
#

# input arguments are:
# 1) maximum amount of currency to sell
# 2) array of ERC1155 token IDs
# 3) array of exact amount of tokens to buy
# 4) maximum time which this transaction can be accepted
@external
func buy_tokens{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    max_currency_amount : Uint256,
    token_ids_len : felt,
    token_ids : Uint256*,
    token_amounts_len : felt,
    token_amounts : Uint256*,
    deadline : felt,
) -> (sold : Uint256):
    alloc_locals

    assert token_ids_len = token_amounts_len

    # Check deadline within bounds
    let (block_timestamp) = get_block_timestamp()
    with_attr error_message("Deadline exceeded"):
        assert_le(block_timestamp, deadline)
    end

    # Loop
    let (currency_amount) = buy_tokens_loop(
        token_ids_len, token_ids, token_amounts_len, token_amounts
    )

    let (above_max_curr) = uint256_le(currency_amount, max_currency_amount)
    with_attr error_message("Maximum currency amount exceeded"):
        assert_not_zero(above_max_curr)
    end

    return (currency_amount)
end

func buy_tokens_loop{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    token_ids_len : felt, token_ids : Uint256*, token_amounts_len : felt, token_amounts : Uint256*
) -> (sold : Uint256):
    alloc_locals

    # Recursive break
    if token_ids_len == 0:
        return (Uint256(0, 0))
    end

    let (caller) = get_caller_address()
    let (contract) = get_contract_address()

    let (token_address_) = token_address.read()
    let (currency_address_) = currency_address.read()

    let (royalty_fee_thousands_) = royalty_fee_thousands.read()
    let (royalty_fee_address_) = royalty_fee_address.read()

    # Read current reserve levels
    let (currency_reserves_ : Uint256) = currency_reserves.read([token_ids])
    let (token_reserves : Uint256) = IERC1155.balanceOf(token_address_, contract, [token_ids])

    # Calculate prices
    let (currency_amount_sans_royal) = get_buy_price(
        [token_amounts], currency_reserves_, token_reserves
    )

    # Add royalty fee
    let (royalty_fee) = get_royalty_for_price(currency_amount_sans_royal)
    let (currency_amount, _) = uint256_add(currency_amount_sans_royal, royalty_fee)  # Overflow will never happen here

    # Update reserves
    let (new_reserves, add_overflow) = uint256_add(currency_reserves_, currency_amount_sans_royal)
    with_attr error_message("Currency value overflow"):
        assert add_overflow = 0
    end
    currency_reserves.write([token_ids], new_reserves)

    # Transfer currency and purchased tokens
    IERC20.transferFrom(currency_address_, caller, contract, currency_amount)
    tempvar syscall_ptr : felt* = syscall_ptr
    IERC1155.safeTransferFrom(token_address_, contract, caller, [token_ids], [token_amounts])
    IERC20.transfer(currency_address_, royalty_fee_address_, royalty_fee)  # Royalty

    # Emit event
    tokens_purchased.emit(caller, currency_amount, [token_ids], [token_amounts])

    # Recurse
    let (currency_total) = buy_tokens_loop(
        token_ids_len - 1,
        token_ids + Uint256.SIZE,
        token_amounts_len - 1,
        token_amounts + Uint256.SIZE,
    )
    let (currency_sold, add_overflow) = uint256_add(currency_total, currency_amount)
    with_attr error_message("Total currency overflow"):
        assert add_overflow = 0
    end

    return (currency_sold)
end

# input arguments are
# 1) maximum amount of currency to buy
# 2) array of ERC1155 token IDs
# 3) array of exact amount of token to sell
# 4) maximum time which this transaction can be accepted

# FIXME IERC1155 doesn't have a call back when using ERC1155.safeTransfer.
# User will need to `setApprovalForAll` to this contract, which poses a security risk for repeat transactions.
@external
func sell_tokens{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    min_currency_amount : Uint256,
    token_ids_len : felt,
    token_ids : Uint256*,
    token_amounts_len : felt,
    token_amounts : Uint256*,
    deadline : felt,
) -> (sold : Uint256):
    alloc_locals

    assert token_ids_len = token_amounts_len

    # Check deadline within bounds
    let (block_timestamp) = get_block_timestamp()
    with_attr error_message("Deadline exceeded"):
        assert_le(block_timestamp, deadline)
    end

    # Loop
    let (currency_amount) = sell_tokens_loop(
        token_ids_len, token_ids, token_amounts_len, token_amounts
    )

    # Check min_currency_amount
    let (above_min) = uint256_le(min_currency_amount, currency_amount)
    with_attr error_message("Below minimum currency amount"):
        assert_not_zero(above_min)
    end

    return (currency_amount)
end

func sell_tokens_loop{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    token_ids_len : felt, token_ids : Uint256*, token_amounts_len : felt, token_amounts : Uint256*
) -> (sold : Uint256):
    alloc_locals

    # Recursive break
    if token_ids_len == 0:
        return (Uint256(0, 0))
    end

    let (caller) = get_caller_address()
    let (contract) = get_contract_address()

    let (token_address_) = token_address.read()
    let (currency_address_) = currency_address.read()

    let (royalty_fee_thousands_) = royalty_fee_thousands.read()
    let (royalty_fee_address_) = royalty_fee_address.read()

    # Read current reserve levels
    let (currency_reserves_ : Uint256) = currency_reserves.read([token_ids])
    let (token_reserves : Uint256) = IERC1155.balanceOf(token_address_, contract, [token_ids])

    # Take the token amount
    IERC1155.safeTransferFrom(token_address_, caller, contract, [token_ids], [token_amounts])

    # Calculate prices
    let (currency_amount_sans_royal) = get_sell_price(
        [token_amounts], currency_reserves_, token_reserves
    )

    # Add royalty fee
    let (royalty_fee) = get_royalty_for_price(currency_amount_sans_royal)
    let (currency_amount) = uint256_sub(currency_amount_sans_royal, royalty_fee)

    # Transfer currency
    IERC20.transfer(currency_address_, caller, currency_amount)
    tempvar syscall_ptr : felt* = syscall_ptr
    IERC20.transfer(currency_address_, royalty_fee_address_, royalty_fee)  # Royalty

    # Update reserves
    let (new_reserves) = uint256_sub(currency_reserves_, currency_amount_sans_royal)
    currency_reserves.write([token_ids], new_reserves)

    # Emit event
    currency_purchased.emit(caller, currency_amount, [token_ids], [token_amounts])

    # Recurse
    let (currency_total) = sell_tokens_loop(
        token_ids_len - 1,
        token_ids + Uint256.SIZE,
        token_amounts_len - 1,
        token_amounts + Uint256.SIZE,
    )
    let (currency_owed, add_overflow) = uint256_add(currency_total, currency_amount)
    with_attr error_message("Total currency overflow"):
        assert add_overflow = 0
    end

    return (currency_owed)
end

#
# Pricing
#

# input argument:
# 1) price without royalty amount
@view
func get_royalty_for_price{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    price_sans_royalty : Uint256
) -> (price : Uint256):
    alloc_locals

    let (royalty_fee_thousands_) = royalty_fee_thousands.read()

    # Add royalty fee
    let (currency_mul_royal_thou, mul_overflow) = uint256_mul(
        price_sans_royalty, royalty_fee_thousands_
    )
    with_attr error_message("Royalty too large"):
        assert mul_overflow = Uint256(0, 0)
    end
    let (royalty_fee, _) = uint256_unsigned_div_rem(currency_mul_royal_thou, Uint256(1000, 0))  # Ignore remainder

    return (royalty_fee)
end

# input arguments are:
# 1) exact amount of token to buy
# 2) currency reserve amount
# 3) token reserve amount
@view
func get_buy_price{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    token_amount : Uint256, currency_reserves : Uint256, token_reserves : Uint256
) -> (price : Uint256):
    alloc_locals

    # LP fee is used to withold currency as reward to LP providers
    let (lp_fee_thousands_) = lp_fee_thousands.read()
    let (lp_fee) = uint256_sub(Uint256(1000, 0), lp_fee_thousands_)

    # Calculate price
    let (numerator, mul_overflow) = uint256_mul(currency_reserves, token_amount)
    with_attr error_message("Values too large"):
        assert mul_overflow = Uint256(0, 0)
    end
    let (denominator) = uint256_sub(token_reserves, token_amount)

    # Add LP fee
    let (numerator, mul_overflow) = uint256_mul(numerator, Uint256(1000, 0))
    with_attr error_message("Numerator overflow"):
        assert mul_overflow = Uint256(0, 0)
    end
    let (denominator, mul_overflow) = uint256_mul(denominator, lp_fee)
    with_attr error_message("Denominator overflow"):
        assert mul_overflow = Uint256(0, 0)
    end

    # Calculate price
    let (price, remainder) = uint256_unsigned_div_rem(numerator, denominator)

    # Return value if no remainder
    let (is_z) = uint256_eq(remainder, Uint256(0, 0))
    if is_z == (1):
        return (price)
    end

    # Round up when there is a remainder, to favour LP providers
    let (price, _) = uint256_add(price, Uint256(1, 0))
    return (price)
end

# input arguments are:
# 1) exact amount of token to buy
# 2) currency reserve amount
# 3) token reserve amount
@view
func get_buy_price_with_royalty{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    token_amount : Uint256, currency_reserves : Uint256, token_reserves : Uint256
) -> (price : Uint256):
    alloc_locals

    let (price_sans_royalty) = get_buy_price(token_amount, currency_reserves, token_reserves)
    let (royalty_fee) = get_royalty_for_price(price_sans_royalty)
    let (price, _) = uint256_add(price_sans_royalty, royalty_fee)  # Will never overflow

    return (price)
end

# input arguments are:
# 1) exact amount of token to sell
# 2) currency reserve amount
# 3) token reserve amount
@view
func get_sell_price{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    token_amount : Uint256, currency_reserves : Uint256, token_reserves : Uint256
) -> (price : Uint256):
    alloc_locals

    # LP fee is used to withold currency as reward to LP providers
    let (lp_fee_thousands_) = lp_fee_thousands.read()
    let (lp_fee) = uint256_sub(Uint256(1000, 0), lp_fee_thousands_)

    # Apply LP fee to token amount
    let (token_amount_w_fee, mul_overflow) = uint256_mul(token_amount, lp_fee)
    with_attr error_message("LP fee overflow"):
        assert mul_overflow = Uint256(0, 0)
    end

    # Calculate price
    let (numerator, mul_overflow) = uint256_mul(token_amount_w_fee, currency_reserves)
    with_attr error_message("Price numerator overflow"):
        assert mul_overflow = Uint256(0, 0)
    end
    let (denominator, mul_overflow) = uint256_mul(token_reserves, Uint256(1000, 0))
    with_attr error_message("LP fee buffer denominator overflow"):
        assert mul_overflow = Uint256(0, 0)
    end
    let (denominator_fee, is_overflow) = uint256_add(denominator, token_amount_w_fee)
    with_attr error_message("Price denominator overflow"):
        assert is_overflow = 0
    end

    let (price, _) = uint256_unsigned_div_rem(numerator, denominator_fee)
    # Rounding errors favour the contract
    return (price)
end

# input arguments are:
# 1) exact amount of token to sell
# 2) currency reserve amount
# 3) token reserve amount
@view
func get_sell_price_with_royalty{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    token_amount : Uint256, currency_reserves : Uint256, token_reserves : Uint256
) -> (price : Uint256):
    alloc_locals

    let (price_sans_royalty) = get_sell_price(token_amount, currency_reserves, token_reserves)
    let (royalty_fee) = get_royalty_for_price(price_sans_royalty)
    let (price) = uint256_sub(price_sans_royalty, royalty_fee)

    return (price)
end

#
# Recieving tokens
#

@external
func onERC1155Received{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    operator : felt, _from : felt, id : Uint256, value : Uint256
) -> (selector : felt):
    return (ON_ERC1155_RECEIVED_SELECTOR)
end

#
# Getters
#

@view
func get_currency_address{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    currency_address : felt
):
    return currency_address.read()
end

@view
func get_token_address{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    token_address : felt
):
    return token_address.read()
end

@view
func get_currency_reserves{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    token_id : Uint256
) -> (currency_reserves : Uint256):
    return currency_reserves.read(token_id)
end

@view
func get_lp_fee_thousands{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    lp_fee_thousands : Uint256
):
    return lp_fee_thousands.read()
end

#
# ERC 1155 for LP tokens
#

@view
func supportsInterface(interface_id : felt) -> (is_supported : felt):
    if interface_id == IERC1155_RECEIVER_ID:
        return (1)
    end
    return ERC1155_supportsInterface(interface_id)
end

@view
func uri{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (uri : felt):
    return ERC1155_uri()
end

@view
func balanceOf{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    account : felt, id : Uint256
) -> (balance : Uint256):
    return ERC1155_balanceOf(account, id)
end

@view
func balanceOfBatch{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    accounts_len : felt, accounts : felt*, ids_len : felt, ids : Uint256*
) -> (balances_len : felt, balances : Uint256*):
    return ERC1155_balanceOfBatch(accounts_len, accounts, ids_len, ids)
end

@view
func isApprovedForAll{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    account : felt, operator : felt
) -> (is_approved : felt):
    return ERC1155_isApprovedForAll(account, operator)
end

@external
func setApprovalForAll{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    operator : felt, approved : felt
):
    ERC1155_setApprovalForAll(operator, approved)
    return ()
end

@external
func safeTransferFrom{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    _from : felt, to : felt, id : Uint256, amount : Uint256
):
    ERC1155_safeTransferFrom(_from, to, id, amount)
    return ()
end

@external
func safeBatchTransferFrom{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    _from : felt, to : felt, ids_len : felt, ids : Uint256*, amounts_len : felt, amounts : Uint256*
):
    ERC1155_safeBatchTransferFrom(_from, to, ids_len, ids, amounts_len, amounts)
    return ()
end
