pragma solidity 0.8.6;
import "./E2E_Helper.sol";

contract E2E_Deposit_Withdraw is E2E_Helper {
    event DepositFailed(string reason, uint256 risky, uint256 stable);
    event DepositRevert(uint256 risky, uint256 stable);

    struct MarginHelper {
        uint128 marginRisky;
        uint128 marginStable;
    }

    function populate_margin_helper(address recipient) internal returns (MarginHelper memory helper) {
        (uint128 risky, uint128 stable) = engine.margins(recipient);
        helper.marginRisky = risky;
        helper.marginStable = stable;
    }

    function check_deposit_withdraw_safe(uint256 riskyAmount, uint256 stableAmount) public {
        address recipient = address(this);
        MarginHelper memory precall = populate_margin_helper(recipient);
        //ensures that delRisky and delStable are at least 1 and not too large to overflow the deposit
        uint256 delRisky = E2E_Helper.one_to_max_uint64(riskyAmount);
        uint256 delStable = E2E_Helper.one_to_max_uint64(stableAmount);
        mint_tokens(delRisky, delStable);
        deposit_should_succeed(recipient, delRisky, delStable);
        withdraw_should_succeed(recipient, delRisky, delStable);

        MarginHelper memory postcall = populate_margin_helper(recipient);
        assert(precall.marginRisky == postcall.marginRisky);
        assert(precall.marginStable == postcall.marginStable);
    }

    function deposit_with_safe_range(
        address recipient,
        uint256 delRisky,
        uint256 delStable
    ) public {
        //ensures that delRisky and delStable are at least 1 and not too large to overflow the deposit
        delRisky = E2E_Helper.one_to_max_uint64(delRisky);
        delStable = E2E_Helper.one_to_max_uint64(delStable);
        mint_tokens(delRisky, delStable);
        deposit_should_succeed(recipient, delRisky, delStable);
    }

    function deposit_zero_zero(address recipient) public {
        deposit_should_revert(recipient, 0, 0);
    }

    function deposit_should_revert(
        address recipient,
        uint256 delRisky,
        uint256 delStable
    ) internal {
        try engine.deposit(recipient, delRisky, delStable, abi.encode(0)) {
            assert(false);
        } catch {
            assert(true);
        }
    }

    function deposit_should_succeed(
        address recipient,
        uint256 delRisky,
        uint256 delStable
    ) internal {
        MarginHelper memory precall = populate_margin_helper(recipient);
        uint256 balanceSenderRiskyBefore = risky.balanceOf(address(this));
        uint256 balanceSenderStableBefore = stable.balanceOf(address(this));
        uint256 balanceEngineRiskyBefore = risky.balanceOf(address(engine));
        uint256 balanceEngineStableBefore = stable.balanceOf(address(engine));

        try engine.deposit(recipient, delRisky, delStable, abi.encode(0)) {
            // check margins
            MarginHelper memory postcall = populate_margin_helper(recipient);
            assert(postcall.marginRisky == precall.marginRisky + delRisky);
            assert(postcall.marginStable == precall.marginStable + delStable);
            // check token balances
            uint256 balanceSenderRiskyAfter = risky.balanceOf(address(this));
            uint256 balanceSenderStableAfter = stable.balanceOf(address(this));
            uint256 balanceEngineRiskyAfter = risky.balanceOf(address(engine));
            uint256 balanceEngineStableAfter = stable.balanceOf(address(engine));
            assert(balanceSenderRiskyAfter == balanceSenderRiskyBefore - delRisky);
            assert(balanceSenderStableAfter == balanceSenderStableBefore - delStable);
            assert(balanceEngineRiskyAfter == balanceEngineRiskyBefore + delRisky);
            assert(balanceEngineStableAfter == balanceEngineStableBefore + delStable);
        } catch {
            uint256 balanceOfThisRisky = risky.balanceOf(address(this));
            uint256 balanceOfThisStable = stable.balanceOf(address(this));
            emit DepositRevert(balanceOfThisRisky, balanceOfThisStable);
            assert(false);
        }
    }

    function withdraw_with_safe_range(
        address recipient,
        uint256 delRisky,
        uint256 delStable
    ) public {
        require(recipient != address(0));
        //ensures that delRisky and delStable are at least 1 and not too large to overflow the deposit
        delRisky = E2E_Helper.one_to_max_uint64(delRisky);
        delStable = E2E_Helper.one_to_max_uint64(delStable);
        MarginHelper memory senderMargins = populate_margin_helper(address(this));
        if (senderMargins.marginRisky < delRisky || senderMargins.marginStable < delStable) {
            withdraw_should_revert(recipient, delRisky, delStable);
        } else {
            withdraw_should_succeed(recipient, delRisky, delStable);
        }
    }

    function withdraw_zero_zero(address recipient) public {
        withdraw_should_revert(recipient, 0, 0);
    }
    function withdraw_zero_address_recipient(uint256 delRisky, uint256 delStable) public {
        delRisky = E2E_Helper.one_to_max_uint64(delRisky);
        delStable = E2E_Helper.one_to_max_uint64(delStable);
        withdraw_should_revert(address(0), 0, 0);
    }

    function withdraw_should_revert(
        address recipient,
        uint256 delRisky,
        uint256 delStable
    ) internal {
        try engine.withdraw(recipient, delRisky, delStable) {
            assert(false);
        } catch {
            assert(true);
        }
    }

    event Withdraw(
        uint128 marginRiskyBefore,
        uint128 marginStableBefore,
        uint256 delRisky,
        uint256 delStable,
        address sender, 
        address originator
    );
    event FailureReason(string reason);

    function withdraw_should_succeed(
        address recipient,
        uint256 delRisky,
        uint256 delStable
    ) internal {
        address originator = address(this);
        MarginHelper memory precallSender = populate_margin_helper(originator);
        MarginHelper memory precallRecipient = populate_margin_helper(recipient);
        uint256 balanceRecipientRiskyBefore = risky.balanceOf(recipient);
        uint256 balanceRecipientStableBefore = stable.balanceOf(recipient);
        uint256 balanceEngineRiskyBefore = risky.balanceOf(address(engine));
        uint256 balanceEngineStableBefore = stable.balanceOf(address(engine));
        emit Withdraw(precallSender.marginRisky, precallSender.marginStable, delRisky, delStable, msg.sender, originator);

        try engine.withdraw(recipient, delRisky, delStable) {
            // check margins on msg.sender
            MarginHelper memory postcallThis = populate_margin_helper(originator);
            assert(postcallThis.marginRisky == precallSender.marginRisky - delRisky);
            assert(postcallThis.marginStable == precallSender.marginStable - delStable);
            // check margins on recipient
            MarginHelper memory postCallRecipient = populate_margin_helper(recipient);
            assert(postCallRecipient.marginRisky == precallRecipient.marginRisky);
            assert(postCallRecipient.marginStable == precallRecipient.marginStable);
            //check token balances
            uint256 balanceRecipientRiskyAfter = risky.balanceOf(recipient);
            uint256 balanceRecipientStableAfter = stable.balanceOf(recipient);
            uint256 balanceEngineRiskyAfter = risky.balanceOf(address(engine));
            uint256 balanceEngineStableAfter = stable.balanceOf(address(engine));
            assert(balanceRecipientRiskyAfter == balanceRecipientRiskyBefore + delRisky);
            assert(balanceRecipientStableAfter == balanceRecipientStableBefore + delStable);
            assert(balanceEngineRiskyAfter == balanceEngineRiskyBefore - delRisky);
            assert(balanceEngineStableAfter == balanceEngineStableBefore - delStable);
        } catch {
            assert(false);
        }
    }

    function depositCallback(
        uint256 delRisky,
        uint256 delStable,
        bytes calldata data
    ) external {
        executeCallback(delRisky, delStable);
    }
}