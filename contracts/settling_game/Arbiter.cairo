# ____ARBITER___
#   The Arbiter has authority over the ModuleController.
#   Responsible for deciding how the controller administers authority.
#   Can be replaced by a vote-based module by calling the
#   appoint_new_arbiter() in the ModuleController.
#   Has an Owner, that may itself be a multisig account contract.
#
# MIT License

%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_not_zero
from starkware.starknet.common.syscalls import get_caller_address

from contracts.settling_game.interfaces.imodules import IModuleController

from openzeppelin.access.ownable import (
    Ownable_initializer,
    Ownable_only_owner,
    Ownable_transfer_ownership,
)
from openzeppelin.utils.constants import TRUE, FALSE

@storage_var
func controller_address() -> (address : felt):
end

# 1=locked.
@storage_var
func lock() -> (bool : felt):
end

@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(owner : felt):
    # Whoever deploys the arbiter sets the only owner.
    Ownable_initializer(owner)
    return ()
end

# Called to save the address of the ModuleController.
@external
func set_address_of_controller{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    contract_address : felt
):
    Ownable_only_owner()
    let (locked) = lock.read()
    # Locked starts as zero
    assert_not_zero(1 - locked)
    lock.write(1)

    controller_address.write(contract_address)
    return ()
end

# Called to replace the contract that controls the Arbiter.
@external
func replace_self{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    new_arbiter_address : felt
):
    Ownable_only_owner()
    let (controller) = controller_address.read()
    # The ModuleController has a fixed address. The Arbiter
    # may be upgraded by calling the ModuleController and declaring
    # the new Arbiter.
    IModuleController.appoint_new_arbiter(
        contract_address=controller, new_arbiter=new_arbiter_address
    )
    return ()
end

@external
func appoint_new_owner{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    new_owner_address : felt
):
    Ownable_only_owner()
    Ownable_transfer_ownership(new_owner_address)
    return ()
end

# Called to approve a deployed module as identified by an ID.
@external
func appoint_contract_as_module{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    module_address : felt, module_id : felt
):
    Ownable_only_owner()
    let (controller) = controller_address.read()
    # Call the ModuleController and enable the new address.
    IModuleController.set_address_for_module_id(
        contract_address=controller, module_id=module_id, module_address=module_address
    )
    return ()
end

@external
func set_external_contract_address{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr
}(address : felt, contract_id : felt):
    Ownable_only_owner()
    let (controller) = controller_address.read()
    # Call the ModuleController and enable the new address.
    IModuleController.set_address_for_external_contract(controller, contract_id, address)
    return ()
end

# Called to authorise write access of one module to another.
@external
func approve_module_to_module_write_access{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr
}(module_id_doing_writing : felt, module_id_being_written_to : felt):
    Ownable_only_owner()
    let (controller) = controller_address.read()
    IModuleController.set_write_access(
        contract_address=controller,
        module_id_doing_writing=module_id_doing_writing,
        module_id_being_written_to=module_id_being_written_to,
    )
    return ()
end

@external
func batch_set_controller_addresses{
    syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr
}(
    module_01_addr : felt,
    module_02_addr : felt,
    module_03_addr : felt,
    module_04_addr : felt,
    module_05_addr : felt,
    module_06_addr : felt,
    module_07_addr : felt,
    module_08_addr : felt,
    module_09_addr : felt,
):
    Ownable_only_owner()
    let (controller) = controller_address.read()
    IModuleController.set_initial_module_addresses(
        controller,
        module_01_addr,
        module_02_addr,
        module_03_addr,
        module_04_addr,
        module_05_addr,
        module_06_addr,
        module_07_addr,
        module_08_addr,
        module_09_addr,
    )
    return ()
end
