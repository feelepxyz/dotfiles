#!/bin/bash

# Install latest node
nodenv install --list
nodenv install 10.11.0
nodenv global 10.11.0
nodenv rehash

npm update -g
