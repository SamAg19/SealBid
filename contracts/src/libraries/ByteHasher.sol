// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ByteHasher
 * @author Worldcoin
 *
 * @notice A helper library for hashing arbitrary bytes into a field element
 * compatible with the World ID ZK proof system.
 *
 * @dev World ID proofs operate over the BN254 scalar field. This library
 * hashes input bytes via keccak256 and right-shifts by 8 bits to ensure
 * the result fits within the field's prime order. Used to compute
 * signalHash and externalNullifierHash for on-chain proof verification.
 */
library ByteHasher {
    /**
     * @notice Hashes arbitrary bytes into a uint256 field element.
     * @dev Computes keccak256 of the packed input, then shifts right by 8 bits
     * to fit within the BN254 scalar field (≈254 bits).
     * @param value The bytes to hash.
     * @return The resulting field element as uint256.
     */
    function hashToField(bytes memory value) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(value))) >> 8;
    }
}