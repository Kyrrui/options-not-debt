# pragma version ==0.4.3
"""
@title MockUSDC — TESTNET-ONLY mintable 6-decimal stable for Gimbal P1 shorts
@notice A minimal, OPEN-MINT 6-decimal ERC20 standing in for USDC on Sepolia so the
        debt-free short stack (PutOptionSeries + GimbalShortVault) has a hard ~$1
        collateral the dapp builder and testers can mint freely. NOT a real stablecoin,
        NO peg, NO issuer — anyone can mint any amount. Sepolia testnet only; never use
        on mainnet (real shorts must lock real USDC; see short-series-spec.md F-FREEZE).
"""

from ethereum.ercs import IERC20

implements: IERC20

event Transfer:
    sender: indexed(address)
    receiver: indexed(address)
    value: uint256

event Approval:
    owner: indexed(address)
    spender: indexed(address)
    value: uint256

DECIMALS: public(constant(uint8)) = 6

totalSupply: public(uint256)
balanceOf: public(HashMap[address, uint256])
allowance: public(HashMap[address, HashMap[address, uint256]])


@external
@view
def name() -> String[32]:
    return "Mock USD Coin"


@external
@view
def symbol() -> String[8]:
    return "USDC"


@external
@view
def decimals() -> uint8:
    return DECIMALS


@external
def transfer(to: address, amount: uint256) -> bool:
    assert to != empty(address), "zero receiver"
    self.balanceOf[msg.sender] -= amount
    self.balanceOf[to] += amount
    log Transfer(sender=msg.sender, receiver=to, value=amount)
    return True


@external
def transferFrom(owner: address, to: address, amount: uint256) -> bool:
    assert to != empty(address), "zero receiver"
    allowed: uint256 = self.allowance[owner][msg.sender]
    if allowed != max_value(uint256):
        self.allowance[owner][msg.sender] = allowed - amount
    self.balanceOf[owner] -= amount
    self.balanceOf[to] += amount
    log Transfer(sender=owner, receiver=to, value=amount)
    return True


@external
def approve(spender: address, amount: uint256) -> bool:
    self.allowance[msg.sender][spender] = amount
    log Approval(owner=msg.sender, spender=spender, value=amount)
    return True


@external
def mint(to: address, amount: uint256):
    """@notice Open faucet — anyone mints any amount. TESTNET ONLY."""
    self.totalSupply += amount
    self.balanceOf[to] += amount
    log Transfer(sender=empty(address), receiver=to, value=amount)
