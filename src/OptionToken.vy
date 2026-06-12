# pragma version ==0.4.3
"""
@title OptionToken — one leg (P or N) of an option pair
@notice Minimal ERC20. Minting and burning are restricted to the
        OptionSeries that deployed this token. Deployed via EIP-5202
        blueprint by OptionSeries.
@dev    Design follows ethresear.ch t/25036: P and N are fungible claims
        on the ETH locked in their series; P + N always redeems 1:1 ETH.
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

NAME: public(immutable(String[512]))
SYMBOL: public(immutable(String[512]))
DECIMALS: public(constant(uint8)) = 18
MINTER: public(immutable(address))

totalSupply: public(uint256)
balanceOf: public(HashMap[address, uint256])
allowance: public(HashMap[address, HashMap[address, uint256]])


@deploy
def __init__(name: String[512], symbol: String[512], minter: address):
    NAME = name
    SYMBOL = symbol
    MINTER = minter


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
    assert msg.sender == MINTER, "not minter"
    assert to != empty(address), "zero receiver"
    self.totalSupply += amount
    self.balanceOf[to] += amount
    log Transfer(sender=empty(address), receiver=to, value=amount)


@external
def burn(owner: address, amount: uint256):
    assert msg.sender == MINTER, "not minter"
    self.balanceOf[owner] -= amount
    self.totalSupply -= amount
    log Transfer(sender=owner, receiver=empty(address), value=amount)
